// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/**
 * @title KipuBank V2
 * @notice Contrato que demuestra operaciones de depósito y retiro de ETH, Multi-token, AccessControl
 * @notice El bankcap global forzado a usar USD (6 decimales)
 * @dev Contrato desarrollado para ETH Kipu (Talento Tech) - Consorte Mañana
 * @author Gabriel Liz Ovelar - @lzov
 * @custom:security No usar en producción! */

import { ReentrancyGuard} from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/security/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract KipuBankV2 is ReentrancyGuard, AccessControl, Pausable {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/
    uint8 public constant USDC_DECIMALS = 6; // internal USD scale (USDC-like)

    /*//////////////////////////////////////////////////////////////
                                   ROLES
    //////////////////////////////////////////////////////////////*/
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /*//////////////////////////////////////////////////////////////
                                STATE VARIABLES
    //////////////////////////////////////////////////////////////*/
    /// @notice Chainlink ETH/USD feed (8 decimals)
    AggregatorV3Interface public immutable i_ethPriceFeed;

    /// @notice withdraw limit (in native token units for the token used)
    uint256 public immutable i_withdrawLimit;

    /// @notice bank cap in USD with 6 decimals (USD * 1e6)
    uint256 public immutable i_bankCapUsd;

    /// @notice user balances: token => user => amount (native token smallest units)
    mapping(address => mapping(address => uint256)) private s_balances;

    /// @notice token => Chainlink price feed (price of 1 token in USD, 8 decimals)
    mapping(address => AggregatorV3Interface) public s_tokenPriceFeed;

    /// @notice total value locked expressed in USD with 6 decimals
    uint256 public s_totalUsdLocked; // USD * 1e6

    /// @notice counters
    uint256 public s_totalDepositsCount;
    uint256 public s_totalWithdrawalsCount;

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    event Deposit(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 valueUsd6
    );
    event Withdraw(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 valueUsd6
    );
    event TokenPriceFeedSet(address indexed token, address indexed feed);
    event EmergencyWithdrawal(
        address indexed to,
        uint256 amount,
        address indexed by
    );

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    error InvalidParameter(string reason);
    error ZeroAmount();
    error BankCapExceeded(uint256 attemptedDepositUsd6, uint256 bankCapUsd6);
    error WithdrawLimitExceeded(uint256 requested, uint256 maxAllowed);
    error InsufficientBalance(uint256 available, uint256 requested);
    error NoPriceFeedForToken(address token);
    error TransferFailed();

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/
    /**
     * @param _withdrawLimit withdraw limit expressed in native units (e.g. wei or token smallest unit)
     * @param _bankCapUsd bank cap expressed in USD with 6 decimals (USD * 1e6)
     * @param _ethPriceFeed address of Chainlink ETH/USD feed (returns price with 8 decimals)
     */
    constructor(
        uint256 _withdrawLimit,
        uint256 _bankCapUsd,
        address _ethPriceFeed
    ) {
        if (_withdrawLimit == 0) revert InvalidParameter("withdraw limit");
        if (_bankCapUsd == 0) revert InvalidParameter("bank cap");
        if (_ethPriceFeed == address(0)) revert InvalidParameter("eth feed");

        i_withdrawLimit = _withdrawLimit;
        i_bankCapUsd = _bankCapUsd;
        i_ethPriceFeed = AggregatorV3Interface(_ethPriceFeed);

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(OPERATOR_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Deposit native ETH (token == address(0)) or ERC20 token.
     * @dev Must have set token price feed for ERC20 tokens that are not USD-pegged (6 decimals).
     * @param token token address (address(0) for ETH)
     * @param amount amount in native token smallest units (ignored for ETH, use msg.value)
     */
    function deposit(
        address token,
        uint256 amount
    ) external payable nonReentrant whenNotPaused {
        uint256 depositAmountNative;

        // checks
        if (token == address(0)) {
            depositAmountNative = msg.value;
            if (depositAmountNative == 0) revert ZeroAmount();
        } else {
            if (amount == 0) revert ZeroAmount();
            depositAmountNative = amount;
            // transfer after passing checks (we transfer below)
        }

        // compute USD value (6 decimals)
        uint256 depositValueUsd6 = _getUsdValue6(token, depositAmountNative);

        // enforce bank cap
        if (s_totalUsdLocked + depositValueUsd6 > i_bankCapUsd) {
            revert BankCapExceeded(
                s_totalUsdLocked + depositValueUsd6,
                i_bankCapUsd
            );
        }

        // effects
        s_totalUsdLocked += depositValueUsd6;
        s_balances[token][msg.sender] += depositAmountNative;
        s_totalDepositsCount++;

        // interactions: transfer token to contract (for ERC20)
        if (token != address(0)) {
            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                depositAmountNative
            );
        }

        emit Deposit(msg.sender, token, depositAmountNative, depositValueUsd6);
    }

    /**
     * @notice Withdraw native ETH (token == address(0)) or ERC20 token.
     * @param token token address (address(0) for ETH)
     * @param amount amount in native smallest units to withdraw
     */
    function withdraw(
        address token,
        uint256 amount
    ) external nonReentrant whenNotPaused {
        if (amount == 0) revert ZeroAmount();
        if (amount > i_withdrawLimit)
            revert WithdrawLimitExceeded(amount, i_withdrawLimit);

        uint256 userBalance = s_balances[token][msg.sender];
        if (amount > userBalance)
            revert InsufficientBalance(userBalance, amount);

        // compute USD value to reduce totalUsdLocked
        uint256 withdrawValueUsd6 = _getUsdValue6(token, amount);

        // effects
        s_balances[token][msg.sender] = userBalance - amount;
        // protect against underflow although checks above ensure safety
        if (s_totalUsdLocked >= withdrawValueUsd6) {
            s_totalUsdLocked -= withdrawValueUsd6;
        } else {
            s_totalUsdLocked = 0;
        }
        s_totalWithdrawalsCount++;

        // interactions
        if (token == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(token).safeTransfer(msg.sender, amount);
        }

        emit Withdraw(msg.sender, token, amount, withdrawValueUsd6);
    }

    /*//////////////////////////////////////////////////////////////
                                ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Set or update a Chainlink price feed for a token.
     * @dev Price feed should return price in USD with 8 decimals (same format as ETH feed).
     *      For USD-pegged tokens (USDC), you may set the feed to address(0) and the contract
     *      will treat token amounts with 6 decimals as USD value directly.
     */
    function setTokenPriceFeed(
        address token,
        address feed
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        s_tokenPriceFeed[token] = AggregatorV3Interface(feed);
        emit TokenPriceFeedSet(token, feed);
    }

    /**
     * @notice Pause deposits and withdrawals. Controlled by PAUSER_ROLE.
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause.
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Emergency withdrawal by operator/admin (ETH only).
     * @dev Operator or admin can withdraw ETH from contract in emergencies.
     */
    function emergencyWithdraw(
        address payable to,
        uint256 amount
    ) external onlyRole(OPERATOR_ROLE) {
        if (amount == 0) revert ZeroAmount();
        (bool success, ) = to.call{value: amount}("");
        if (!success) revert TransferFailed();
        emit EmergencyWithdrawal(to, amount, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                                VIEW HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns user's balance for a token (native smallest units).
     */
    function getVaultBalance(
        address token,
        address user
    ) external view returns (uint256) {
        return s_balances[token][user];
    }

    /**
     * @notice Returns total USD locked (6 decimals).
     */
    function getTotalUsdLocked() external view returns (uint256) {
        return s_totalUsdLocked;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Get latest ETH price (USD with 8 decimals).
     */
    function _getLatestEthPrice() internal view returns (uint256) {
        (, int256 price, , , ) = i_ethPriceFeed.latestRoundData();
        require(price > 0, "Chainlink: invalid price");
        return uint256(price);
    }

    /**
     * @notice Get USD value (6 decimals) of a token native amount.
     * @dev For token:
     *   - if token == address(0): uses ETH feed
     *   - else if tokenPriceFeed[token] set: uses that feed (price in USD with 8 decimals)
     *   - else if token has 6 decimals and no feed: treated as USD stable (USDC-like)
     *   - otherwise reverts (no reliable price)
     */
    function _getUsdValue6(
        address token,
        uint256 amountNative
    ) internal view returns (uint256) {
        if (token == address(0)) {
            // ETH: amountNative is wei (1e18)
            uint256 price8 = _getLatestEthPrice(); // USD * 1e8
            // amountNative * price8 / 1e18 => USD * 1e8
            // convert 1e8 -> 1e6 (divide by 1e2)
            unchecked {
                return ((amountNative * price8) / 1e18) / 1e2;
            }
        } else {
            AggregatorV3Interface feed = s_tokenPriceFeed[token];
            if (address(feed) != address(0)) {
                // token has feed: price is USD * 1e8 per 1 token unit
                uint256 price8;
                (, int256 p, , , ) = feed.latestRoundData();
                require(p > 0, "Chainlink token feed invalid");
                price8 = uint256(p);

                uint8 tokenDecimals = IERC20Metadata(token).decimals(); // e.g. 6, 8, 18
                // amountNative * price8 / (10 ** tokenDecimals) => USD * 1e8
                // convert 1e8 -> 1e6
                unchecked {
                    return
                        ((amountNative * price8) / (10 ** tokenDecimals)) / 1e2;
                }
            } else {
                // no feed: accept as USDC-like if the token has 6 decimals
                uint8 tokenDecimals = IERC20Metadata(token).decimals();
                if (tokenDecimals == USDC_DECIMALS) {
                    // amountNative is already USDC-like: USD * 1e6
                    return amountNative;
                } else {
                    revert NoPriceFeedForToken(token);
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                FALLBACKS
    //////////////////////////////////////////////////////////////*/
    receive() external payable {
        revert();
    }

    fallback() external payable {
        revert();
    }
}
