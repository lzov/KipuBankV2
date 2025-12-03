# KipuBank V2 🏦

> Smart contract bancario multi-token con integración de oráculos Chainlink y control de acceso basado en roles

[![Solidity](https://img.shields.io/badge/Solidity-0.8.30-363636?logo=solidity)](https://soliditylang.org/)
[![OpenZeppelin](https://img.shields.io/badge/OpenZeppelin-5.0-4E5EE4?logo=openzeppelin)](https://www.openzeppelin.com/)
[![Chainlink](https://img.shields.io/badge/Chainlink-Data_Feeds-375BD2?logo=chainlink)](https://chain.link/)
[![License](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

---

## 📋 Descripción

**KipuBank V2** es la segunda iteración del contrato bancario original, transformándolo en un sistema DeFi multi-token. Este proyecto forma parte del curso ETH Kipu (Talento Tech) y demuestra la aplicación de patrones avanzados de Solidity y arquitectura segura de contratos inteligentes.

## Dirección del contrato desplegado

- Testnet Sepolia: `0x57e900ff4c5e78333b1d4055365f79c4a69a5109`
- Block explorer: [Ver contrato](https://sepolia.etherscan.io/address/0x57e900ff4c5e78333b1d4055365f79c4a69a5109)


### 🎯 Características principales

- ✅ **Multi-token**: Soporte para ETH nativo y tokens ERC-20
- ✅ **Integración Chainlink**: Conversión automática ETH/Token → USD usando Data Feeds
- ✅ **Control de acceso**: Sistema de roles (Admin, Operator, Pauser) con OpenZeppelin AccessControl
- ✅ **Contabilidad unificada**: Todos los valores internos en USD (6 decimales, formato USDC)
- ✅ **Seguridad avanzada**: ReentrancyGuard, Pausable, SafeERC20, custom errors
- ✅ **Gas optimizado**: Variables `immutable`/`constant`, unchecked blocks, divisiones combinadas
- ✅ **Límites configurables**: Bank cap y withdraw limit expresados en USD para consistencia

---

## 🚀 Mejoras sobre V1

| Aspecto | V1 (Original) | V2 (Actual) |
|---------|---------------|-------------|
| **Tokens soportados** | Solo ETH nativo | ETH + ERC-20 multi-token |
| **Precio de activos** | Hardcoded en ETH | Oráculos Chainlink en USD |
| **Contabilidad** | ETH (18 decimals) | USD unificado (6 decimals) |
| **Control de acceso** | Ninguno | Roles (Admin/Operator/Pauser) |
| **Límites** | ETH units (inconsistente) | USD (consistente multi-token) |
| **Seguridad** | Básica | ReentrancyGuard + Pausable |
| **Manejo de errores** | `require()` strings | Custom errors (gas-efficient) |
| **Tokens ERC-20** | No soportados | SafeERC20 + metadata |
| **Escalabilidad** | Limitada | Arquitectura modular |
| **Observabilidad** | Eventos básicos | Eventos indexados detallados |

---

## 🏗️ Arquitectura y Decisiones de Diseño

### 1️⃣ **USD como unidad contable universal**

**Problema**: Con multi-token, ¿cómo comparar 1 ETH (18 decimals) vs 1,000 USDC (6 decimals)?

**Solución**: Convertir todo a USD con 6 decimales (formato USDC) usando Chainlink.

```solidity
// Ejemplo: 1 ETH a $2,000 USD
amountWei = 1e18           // 1 ETH
ethPrice = 2000e8          // $2,000 (8 decimals Chainlink)
valueUSD = 2_000_000_000   // $2,000 (6 decimals internos)
```

**Beneficio**: 
- Bank cap global consistente ($10,000 USD aplica igual a ETH, USDC, DAI, etc.)
- Withdraw limit justo entre tokens (no puedes retirar $100,000 en USDC pero solo $2,000 en ETH)

### 2️⃣ **Chainlink para precios confiables**

**¿Por qué Chainlink?**
- Descentralizado (múltiples nodos validan precios)
- Resistente a manipulación (no depende de un solo exchange)
- Actualización frecuente (cada ~1 hora o cuando hay >0.5% cambio)


**Staleness check**: Rechaza precios >1 hora para evitar exploits durante outages.

### 3️⃣ **Manejo inteligente de decimales**

Cada token tiene decimales diferentes:
- ETH: 18 decimals
- USDC: 6 decimals  
- WBTC: 8 decimals

### 4️⃣ **AccessControl granular**

| Rol | Permisos | Caso de uso |
|-----|----------|-------------|
| `DEFAULT_ADMIN_ROLE` | Gestión de roles, configurar price feeds | Owner del protocolo |
| `OPERATOR_ROLE` | Emergency withdrawals | Multisig de seguridad |
| `PAUSER_ROLE` | Pausar/despausar contratos | Respuesta a incidentes |

**Ventaja**: Separación de privilegios. Un operador puede pausar sin tener control total.

### 5️⃣ **Checks-Effects-Interactions estricto**

```solidity
function withdraw(address token, uint256 amount) external {
    // ✅ CHECKS
    if (amount == 0) revert ZeroAmount();
    if (withdrawValueUsd6 > i_withdrawLimitUsd) revert WithdrawLimitExceeded(...);
    
    // ✅ EFFECTS (cambios de estado)
    s_balances[token][msg.sender] -= amount;
    s_totalUsdLocked -= withdrawValueUsd6;
    
    // ✅ INTERACTIONS (llamadas externas)
    if (token == address(0)) {
        (bool success,) = msg.sender.call{value: amount}("");
    } else {
        IERC20(token).safeTransfer(msg.sender, amount);
    }
}
```

**Protección**: Previene ataques de reentrancy incluso sin guard (defensa en profundidad).


## 📊 Especificaciones Técnicas

| Parámetro | Valor | Notas |
|-----------|-------|-------|
| **Solidity** | 0.8.30 | Última versión estable |
| **Withdraw Limit** | Configurable USD6 | Ej: 1,000 USD = `1_000_000_000` |
| **Bank Cap** | Configurable USD6 | Ej: 10,000 USD = `10_000_000_000` |
| **Price Feed Format** | USD con 8 decimals | Chainlink standard |
| **Internal Accounting** | USD con 6 decimals | USDC-compatible |
| **Staleness Threshold** | 1 hora (3600s) | Configurable en producción |

---

## 🔒 Seguridad

### Medidas implementadas

- ✅ **ReentrancyGuard**: Previene ataques de reentrada
- ✅ **Pausable**: Kill switch en caso de exploit
- ✅ **SafeERC20**: Manejo seguro de tokens no-standard
- ✅ **AccessControl**: Roles granulares, no hay `onlyOwner` absoluto
- ✅ **Custom Errors**: Gas-efficient, stack traces claros
- ✅ **Price validation**: Staleness check + positive price enforcement
- ✅ **Checks-Effects-Interactions**: Patrón de seguridad estándar
- ✅ **Immutable/Constant**: Variables críticas inmutables post-deploy

#
## 👨‍💻 Autor

**Gabriel** - [@lzov](https://github.com/lzov)

*Desarrollado para ETH Kipu (Talento Tech) - Cohorte Mañana*

---

## ⚠️ Disclaimer

```
ESTE CONTRATO ES ÚNICAMENTE PARA FINES EDUCATIVOS.

NO USAR EN PRODUCCIÓN SIN:
- Auditoría de seguridad profesional
- Testing exhaustivo en testnet
```

## 📝 Licencia

Este proyecto está bajo la licencia MIT. Ver [LICENSE](LICENSE) para más detalles.


---
