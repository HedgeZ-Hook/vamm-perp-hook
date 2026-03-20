# HedgedZ — LP-Native Perpetual Trading on Unichain

## Judge Quick Check (Updated)

### Live Deployment (Unichain Sepolia)

> Network: `Unichain Sepolia` (chainId `1301`)

| Component | Address |
|---|---|
| Deployer | `0x91d5e66951c47FbBFaFe57C9Ff42d45c46b6044c` |
| PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| PositionManager | `0xf969Aee60879C54bAAed9F3eD26147Db216Fd664` |
| SwapRouter | `0x9cD2b0a732dd5e023a5539921e0FD1c30E198Dba` |
| USDC | `0x31d0220469e10c4E71834a79b1f276d740d3768F` |
| PerpHook | `0x67592e635186d65c4e9543691ba78fD4295c0Fc0` |
| vETH | `0x067a34AD7F20aa0e0A5c2627e4288e34B1182c8E` |
| vUSDC | `0xa262a8fa5C50216458b65Ca20803f0bC5019FA75` |
| Config | `0x8F7a9a56CA8a8B4832cdCC78e2fe30B87303eD8B` |
| AccountBalance | `0x98F0D3b07705AA97990622f40526beb2A759badB` |
| ClearingHouse | `0x86E3e57eb57B0932EDf2Cf8c1EC2FF573259df17` |
| Vault | `0x5d929A1f25486e455137eD0070E95492b8fd4A73` |
| FundingRate | `0xd1a96b65aD5204685075E3740346FF6E493aB85F` |
| LiquidityController | `0xE1c1BeE251D56233F558403bA378E7AdBcA380D1` |
| InsuranceFund | `0x5934f5EF68bD3aAFBe526E4851e1e6774595a6A7` |
| PriceOracle | `0xE6D19cBA9e4c978688dfbFEf1D63805e4f3D71Be` |
| LiquidationTracker | `0xE6D19cBA9e4c978688dfbFEf1D63805e4f3D71Be` |

### Minimal Repro Flow (for judges)

```bash
# 1) Inspect full system state
forge script 'script/16_InspectSystemState.s.sol:InspectSystemStateUnichainSepolia' \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"

# 2) Inspect LP trader account state (human-readable)
INSPECT_TRADER=0x91d5e66951c47FbBFaFe57C9Ff42d45c46b6044c \
forge script 'script/29_InspectLpAccountState.s.sol:InspectLpAccountStateUnichainSepolia' \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL"

# 3) Trigger manual liquidation (when account is liquidatable)
LIQUIDATE_TRADER=0x91d5e66951c47FbBFaFe57C9Ff42d45c46b6044c \
forge script 'script/31_LiquidateTrader.s.sol:LiquidateTraderUnichainSepolia' \
  --rpc-url "$UNICHAIN_SEPOLIA_RPC_URL" \
  --broadcast
```

### Current Notes (important)

- LP NFT collateral flow: `depositLP`/`withdrawLP` on `Vault`.
- LP-backed perp flow: `script/21_OpenLpPerpPosition` + `script/30_ClosePerpPositionWithSnapshot`.
- Vault now includes insurance backstop pull path via `InsuranceFund.provideVaultLiquidity(...)`.

---

## Full Project Description (Original)

HedgedZ is a Uniswap v4 Hook that turns LP positions into margin collateral for perpetual trading. Instead of withdrawing liquidity, LPs use their inventory value to open leveraged long/short positions via a virtual AMM engine — earning swap fees and trading PnL simultaneously.

---

## The Problem

Uniswap LPs face a dilemma:
- Their capital sits in pools earning swap fees, but they **cannot hedge** impermanent loss or take directional bets without withdrawing.
- To trade perps on external platforms, they must **pull liquidity out**, reducing pool depth and losing fee income.
- Capital is split: **LP capital** and **trading capital** are two separate worlds.

## The Solution

HedgedZ merges these two worlds. An LP position in a spot ETH/USDC pool becomes **usable margin** inside a perpetual trading system — all within one Uniswap v4 hook.

**LP collateral value** is calculated as:

```
Collateral (USDC) = ETH_in_position × ETH_price + USDC_in_position
```

With this margin, LPs can:
- **Go long or short** ETH with leverage
- **Hedge impermanent loss** by shorting ETH proportional to their LP delta
- **Take directional exposure** while still earning swap fees
- **Maintain capital efficiency** — one deposit, multiple yield sources

---

## Architecture Overview

HedgedZ operates across **two Uniswap v4 pools** managed by a single hook contract, backed by an on-chain oracle system.

```
┌────────────────────────────────────────────────────────────────┐
│                         USER (LP + Trader)                     │
│                                                                │
│  1. Deposit USDC as margin            ──────► Vault            │
│  2. Add liquidity to spot pool        ──────► Spot Pool        │
│  3. Open perp position (long/short)   ──────► ClearingHouse    │
└────────────────────────────────────────────────────────────────┘
         │                    │                       │
         ▼                    ▼                       ▼
┌─────────────┐   ┌───────────────────┐   ┌──────────────────────┐
│    Vault    │   │  Spot Pool        │   │   vAMM Pool          │
│  (USDC +   │   │  ETH/USDC (real)  │   │   vETH/vUSDC         │
│   LP value) │   │  + PerpHook       │   │   (virtual tokens)   │
│             │   │                   │   │   + PerpHook          │
└──────┬──────┘   └────────┬──────────┘   └──────────┬───────────┘
       │                   │                          │
       │         LP events captured            Perp swaps executed
       │         by hook → register            by hook → record
       │         as collateral                 positions & PnL
       │                   │                          │
       └───────────────────┴──────────────────────────┘
                           │
                  ┌────────▼────────┐
                  │  AccountBalance │
                  │  (position      │
                  │   ledger)       │
                  └────────┬────────┘
                           │
                  ┌────────▼────────┐
                  │  Reactive       │
                  │  Oracle         │
                  │  (cross-chain   │
                  │   price feed)   │
                  └─────────────────┘
```

---

## Two Pools, One Hook

### Spot Pool — ETH/USDC (Real Tokens)

A standard Uniswap v4 pool where real ETH and USDC are traded. LPs provide liquidity here and earn swap fees as usual. The PerpHook attaches to this pool to:

- **Capture LP mint events** — when a user adds liquidity, the hook registers the LP position in the Vault as collateral.
- **Guard LP removal** — before a user removes liquidity, the hook checks whether the remaining collateral still satisfies margin requirements for any open perp positions. If not, the removal is blocked.
- **Track LP value changes** — as the spot price moves, LP inventory (how much ETH vs USDC the position holds) shifts, and collateral value adjusts accordingly.

### vAMM Pool — vETH/vUSDC (Virtual Tokens)

A Uniswap v4 pool where the tokens are **virtual** — they have no value outside the perp system. This pool serves as the pricing engine for perpetual contracts:

- Virtual tokens are minted in maximum supply to the ClearingHouse. They can only be transferred between whitelisted addresses (ClearingHouse and PoolManager).
- **No real assets are swapped.** When a trader opens a long, the ClearingHouse executes a swap on this pool (buying vETH with vUSDC). The pool's concentrated liquidity math determines the execution price, just like a real swap — but everything is synthetic.
- **Makers can provide liquidity** to the vAMM pool. They earn trading fees from perp traders, similar to how LPs earn fees on spot pools.
- The vAMM pool price reflects supply/demand of the perpetual market. A funding rate mechanism anchors this price back to the spot/index price over time.

**Why use a real v4 pool for the vAMM instead of custom math?**
Because Uniswap v4's PoolManager already provides battle-tested concentrated liquidity, tick-based pricing, and TWAP oracles. There is no reason to rewrite this from scratch.

---

## Core Components

### PerpHook

The hook contract that attaches to both the spot pool and the vAMM pool. It acts as a **traffic controller** — intercepting Uniswap v4 lifecycle events and routing them to the appropriate system contracts.

**On the spot pool:**
| Event | Action |
|---|---|
| `afterAddLiquidity` | Register LP position as collateral in Vault |
| `beforeRemoveLiquidity` | Check margin — revert if collateral would drop below requirement |
| `afterRemoveLiquidity` | Update collateral records in Vault |

**On the vAMM pool:**
| Event | Action |
|---|---|
| `beforeSwap` | Access control — only ClearingHouse can initiate swaps |
| `afterSwap` | Update fee growth for makers, emit position events |
| `afterAddLiquidity` | Track maker liquidity positions |
| `beforeRemoveLiquidity` | Validate maker can withdraw |

### ClearingHouse

The main entry point for traders. It orchestrates the full lifecycle of a perpetual position:

1. **Settle funding** — calculate and apply any pending funding payments before any action.
2. **Execute swap** — call `PoolManager.swap()` on the vAMM pool. The v4 pool handles price discovery and execution; the hook records the trade.
3. **Update ledger** — write position size, open notional, and realized PnL to AccountBalance.
4. **Check margin** — verify the trader has sufficient collateral (USDC balance + LP value + unrealized PnL) to support the new/modified position.

Supported operations:
- `openPosition` — go long or short with specified size and leverage
- `closePosition` — close an existing position fully
- `liquidate` — close an under-collateralized trader's position with a penalty

### AccountBalance

A ledger that tracks every trader's perpetual position per market:

- **Position size** — how much vETH long (+) or short (-)
- **Open notional** — the USDC cost basis of the position
- **Owed realized PnL** — accumulated realized profit/loss from closing or reducing positions, pending settlement to the Vault

It also calculates:
- **Mark price** — a manipulation-resistant price derived from the median of: instant market price, market TWAP, and index price + premium. Used for margin checks and liquidation.
- **Margin requirement** — total absolute position value multiplied by the initial margin ratio (e.g., 10%).
- **Liquidation threshold** — total absolute position value multiplied by the maintenance margin ratio (e.g., 6.25%). When account value drops below this, the position can be liquidated.

### Vault

Manages all collateral and determines whether a trader has enough margin.

**Two types of collateral:**

1. **USDC deposits** — traders deposit USDC directly into the Vault as margin.
2. **LP positions** — when a user adds liquidity to the spot ETH/USDC pool, the hook registers it in the Vault. The LP's inventory value (ETH amount × ETH price + USDC amount) counts as collateral.

**Key calculations:**

```
Account Value = USDC Balance 
              + LP Collateral Value 
              + Unrealized PnL 
              - Pending Funding Payment

Free Collateral = min(Account Value, Total Collateral Value) - Margin Requirement
```

If free collateral drops below zero, the trader cannot open new positions. If account value falls below the maintenance margin requirement, the position becomes liquidatable.

**LP collateral valuation** uses the oracle price to convert LP inventory to USDC terms. As ETH price changes, the LP's ETH/USDC split changes (due to AMM mechanics), and the collateral value adjusts in real time.

### VirtualToken

ERC20 tokens (vETH, vUSDC) used exclusively in the vAMM pool. They enforce a **whitelist**: only the ClearingHouse and PoolManager can transfer them. They have no market value — their sole purpose is to enable the v4 pool's AMM math to function for synthetic perp pricing.

### FundingRate

Anchors the vAMM perpetual price to the spot/index price through periodic payments between longs and shorts:

```
Funding Rate = (vAMM TWAP - Index Price) / 24 hours
```

- If vAMM price > index price: longs pay shorts (discouraging excess longs)
- If vAMM price < index price: shorts pay longs (discouraging excess shorts)

Funding is settled into each trader's realized PnL whenever they interact with the system (open, close, add/remove liquidity). The maximum funding rate is capped to prevent extreme payments during volatile periods.

### InsuranceFund

A safety net for the system:
- Receives a portion of trading fees from the vAMM pool
- Covers bad debt when a liquidated trader's remaining collateral is negative
- Distributes surplus fees to protocol stakeholders when its capacity exceeds a threshold

### Config

System-wide risk parameters:
- **Initial Margin Ratio** (e.g., 10%) — minimum collateral to open a position; determines max leverage (10x)
- **Maintenance Margin Ratio** (e.g., 6.25%) — threshold below which a position can be liquidated
- **Liquidation Penalty** (e.g., 2.5%) — fee charged to the liquidated trader, split between liquidator and InsuranceFund
- **Max Funding Rate** (e.g., 10%) — cap on the per-day funding rate
- **TWAP Interval** (e.g., 15 minutes) — window for time-weighted average price calculations

---

## Reactive Oracle & Price-Triggered Collateral Management

### The Oracle Problem

Perpetual protocols need a reliable **index price** that reflects the true market price of the underlying asset. This price is used for:
- Funding rate calculation (anchoring vAMM to reality)
- Mark price computation (for margin and liquidation checks)
- LP collateral valuation (converting ETH holdings to USDC terms)

A single on-chain price source is vulnerable to manipulation. HedgedZ solves this with a **Reactive Aggregator Oracle** powered by the Reactive Network.

### Reactive Aggregator Oracle

An on-chain contract that builds a canonical ETH/USDC price by aggregating data from multiple chains:

```
┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
│ Ethereum │  │ Unichain │  │   Base   │  │ Optimism │  │ Arbitrum │
│ ETH/USDC │  │ ETH/USDC │  │ ETH/USDC │  │ ETH/USDC │  │ ETH/USDC │
│  pool    │  │  pool    │  │  pool    │  │  pool    │  │  pool    │
└────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘
     │             │             │             │             │
     └─────────────┴─────────────┴─────────────┴─────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │   Reactive Network       │
                    │                          │
                    │  - Ingest pool events    │
                    │  - TWAP per source       │
                    │  - Liquidity weighting   │
                    │  - Outlier filtering     │
                    │  - Publish canonical     │
                    │    price on Unichain     │
                    └────────────┬─────────────┘
                                 │
                    ┌────────────▼─────────────┐
                    │  Oracle Contract         │
                    │  (on Unichain)           │
                    │                          │
                    │  getIndexPrice(interval) │
                    │  → returns TWAP          │
                    └──────────────────────────┘
```

**Pricing methodology:**
- **TWAP windows** — each source provides a time-weighted average, smoothing out short-term noise
- **Liquidity weighting** — pools with deeper liquidity contribute more to the final price, as they are harder to manipulate
- **Outlier filtering** — prices that deviate significantly from the median are discarded to prevent oracle attacks

### Price-Triggered Collateral Management

The Reactive Network does more than just provide a price feed. It enables **reactive triggers** — automated on-chain actions fired when specific conditions are met.

HedgedZ uses reactive triggers for collateral management:

```
┌──────────────────────────────────────────────────────────┐
│                  Reactive Network                        │
│                                                          │
│  Monitor:                                                │
│    - ETH/USDC price across all source chains             │
│    - Significant price movements (e.g., >2% in 5 min)   │
│                                                          │
│  When trigger fires:                                     │
│    → Call Oracle.updatePrice() on Unichain               │
│    → Call ClearingHouse.triggerLiquidationCheck(traders)  │
│       for positions near margin threshold                │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

**Why this matters:**

Without reactive triggers, liquidations only happen when someone manually calls `liquidate()`. In a fast-moving market, this creates a gap:
- ETH drops 20% in minutes
- LP collateral value drops with it
- Perp positions become under-collateralized
- But nobody calls liquidate until an MEV bot or keeper notices

With Reactive Network triggers:
- Price movement is detected **across chains** the moment it happens
- The oracle updates automatically
- A liquidation check is triggered for at-risk positions
- Bad debt is prevented before it accumulates

**Trigger scenarios:**

| Trigger Condition | Action |
|---|---|
| ETH price drops >X% in Y minutes | Update oracle price, flag at-risk positions for liquidation |
| LP collateral value falls below maintenance margin | Initiate liquidation of the LP's perp position |
| vAMM price diverges >Z% from index | Push price update to recalculate funding rate |
| Funding rate exceeds cap threshold | Alert and settle outstanding funding payments |

This makes HedgedZ a **self-maintaining system** — it does not rely solely on external keepers or MEV bots for critical safety operations.

---

## User Flows

### Flow 1: LP Deposits and Earns Fees

```
1. User deposits USDC into Vault                    → margin available
2. User adds liquidity to spot ETH/USDC pool         → earns swap fees
3. PerpHook captures the LP mint event
4. Vault registers LP position as additional collateral
5. User's total margin = USDC balance + LP inventory value
```

### Flow 2: LP Opens a Hedging Short

```
1. User has LP position in ETH/USDC (exposed to IL if ETH drops)
2. User calls ClearingHouse.openPosition(short ETH, 2x leverage)
3. ClearingHouse settles any pending funding
4. ClearingHouse swaps on vAMM pool (sells vETH for vUSDC)
5. PerpHook records the position in AccountBalance
6. Vault verifies: LP collateral + USDC balance ≥ margin requirement ✓
7. User now earns swap fees + is hedged against ETH downside
```

### Flow 3: Price Drops — Reactive Liquidation

```
1. ETH drops 15% across Ethereum, Base, Arbitrum
2. Reactive Network detects the cross-chain price movement
3. Reactive trigger fires:
   a. Oracle contract on Unichain receives updated price
   b. ClearingHouse is called to check at-risk positions
4. Trader X's LP collateral value has dropped (less ETH value)
5. Account value < maintenance margin → liquidatable
6. Liquidator (or reactive trigger) calls liquidate(Trader X)
7. Position closed at mark price, penalty applied
8. If bad debt remains → InsuranceFund absorbs it
```

### Flow 4: LP Tries to Remove Liquidity

```
1. User has LP position as collateral + open perp position
2. User tries to remove liquidity from spot pool
3. PerpHook.beforeRemoveLiquidity fires:
   - Calculates remaining collateral after removal
   - Checks: remaining collateral ≥ margin requirement?
4a. If YES → removal proceeds, Vault updates collateral records
4b. If NO  → transaction reverts ("insufficient margin")
```

### Flow 5: Funding Payment Cycle

```
1. vAMM price is trading above index price (too many longs)
2. Funding rate = positive → longs pay shorts
3. On any interaction (open, close, add/remove liquidity):
   - Pending funding is calculated since last settlement
   - Applied to trader's realized PnL
   - Gradually pushes vAMM price toward index price
4. Reactive trigger can also force funding settlement
   if vAMM diverges significantly from index
```

---

## Why HedgedZ

**Capital Efficient** — LPs earn swap fees, liquidity incentives, and perp trading PnL using the same capital. No need to split funds between LP positions and trading accounts.

**Native Hedging** — Short ETH to offset delta exposure and manage impermanent loss, without ever leaving the Uniswap ecosystem.

**Manipulation Resistant** — Cross-chain aggregated oracle with liquidity weighting and outlier filtering. Mark price uses a three-way median to resist single-source attacks.

**Self-Maintaining** — Reactive Network triggers ensure oracle freshness and timely liquidations, reducing dependency on external keepers.

**Built for Unichain** — Low gas, high throughput, native Uniswap v4 composability. The vAMM leverages v4's concentrated liquidity math directly — no reinvented AMM.

---

## Vision

HedgedZ introduces **Liquidity-Backed Leverage** — turning passive AMM liquidity into programmable margin infrastructure. Every LP position becomes a first-class trading account, and every swap fee earned compounds with every perp trade placed.

The long-term goal: **any LP on Uniswap can hedge, speculate, or earn yield on their position — without ever moving their capital.**
