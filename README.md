<p align="center">
  <img src="asset/GRAVITY LOGO copy.png" alt="Gravity Protocol" width="200"/>
</p>

# Gravity Protocol

Gravity is a flagship payment protocol that converts any ERC20 into MNEE in a single transaction. Route discovery and quoting happen off-chain for flexibility, but every hop, amount, and fee is revalidated on-chain before settlement. This repo packages the Solidity core, the TypeScript client (`GravitySWAP.ts`), mocks, and deployment tooling.

> Need the deep dive? See `docs/ARCHITECHTURE.md` for diagrams, invariants, and storage layouts.

---

## Why Gravity

- **Deterministic settlement** – Every payment ends in MNEE regardless of the payer’s input asset.
- **Trust-minimized routing** – Off-chain BFS handles graph exploration, while `GravityPayment` + `TokenRouter` revalidate paths and quotes on-chain.
- **Uniswap v4 native** – Swaps execute through `MNEESwapHook`, which runs in the hook sandbox and enforces allowlists + per-hop slippage limits before calling `PoolSwapTest`.
- **Observability-first** – Structured `PaymentMade` and `TokenSwap` events fuel analytics, compliance, and receipts.
- **Battle-tested tooling** – Hardhat workspace, mocks, env templates, and the GravitySWAP client make local or Sepolia deployments trivial.

---

## Component Stack

| Layer | Artifact | Responsibilities |
| --- | --- | --- |
| Settlement & Fees | `GravityPayment.sol` | Custodies funds, revalidates swap paths, charges protocol fees, dispatches swaps, stores immutable receipts. |
| Routing Registry | `TokenRouter.sol` | Maintains supported token graph, pool adjacency, liquidity scores, and expected output math. |
| Swap Execution | `MNEESwapHook.sol` | Runs each hop inside a Uniswap v4 hook, enforcing token allowlists, per-hop slippage, and swap fees. |
| Client | `scripts/GravitySWAP.ts` | Discovers optimal paths, quotes expected MNEE, enforces user slippage, and calls `GravityPayment.pay`. |
| Tooling | Mocks, tests, Hardhat config | Local/testnet deployment scripts, deterministic simulations, and regression safety nets. |

---

## Protocol Data Flow

1. **Route discovery (off-chain)** – `GravitySWAP.ts` builds a graph from `TokenRouter.getNeighbors`, runs BFS up to `MAX_HOPS`, and prices candidates with `calculateExpectedOutput`.
2. **Payload formation** – The client clamps slippage, ensures ERC20 approvals, and assembles `(eventId, tokenIn, amountIn, recipient, minMNEEOut, swapPath)`.
3. **On-chain validation** – `GravityPayment.pay` reruns `validatePath`, checks balances/allowances, computes protocol fees, and streams funds to `MNEESwapHook`.
4. **Hook execution** – Each hop is guarded by token allowlists, per-hop slippage, and swap fees before calling `PoolSwapTest`. Failures revert atomically.
5. **Settlement + telemetry** – Proceeds return, `GravityPayment` credits the recipient, persists `payments[paymentId]`, and emits `PaymentMade` + per-hop `TokenSwap` events.

---

## Get Started

### Prerequisites
- Node.js 18+
- `pnpm`
- Git

### Install & bootstrap
```bash
git clone <repository-url>
cd Gravity-ERC20/Gravity
pnpm install
cp .env.example .env
```
Populate `.env` with:
- `RPC_URL` – local Anvil/Hardhat or remote (Infura/Alchemy) endpoint
- `PRIVATE_KEY` – deployer/signer (never commit!)
- `GRAVITY_PAYMENT_ADDRESS`, `TOKEN_ROUTER_ADDRESS`, `MNEE_TOKEN_ADDRESS` – set after deployment
- Optional overrides for Permit2 / Universal Router (auto-filled for chain `11155111`)

---

## Core Workflows

### Compile & Test
```bash
pnpm hardhat compile
pnpm hardhat test              # entire suite
pnpm hardhat test solidity     # solidity-only
pnpm hardhat test nodejs       # node-based tests
```

### Deploy Contracts
```bash
# Local Hardhat chain
pnpm hardhat run scripts/deploy.ts --network hardhat

# Sepolia (requires funded key + RPC)
pnpm hardhat run scripts/deploy.ts --network sepolia
```

### Execute a Payment with GravitySWAP
```bash
pnpm ts-node scripts/GravitySWAP.ts
```
GravitySWAP will:
1. Load `.env` and network defaults (Permit2, Universal Router, PoolManager, etc.).
2. Discover the top route, print path/price impact/confidence.
3. Ensure allowances, compute slippage-safe `minMNEEOut`, and call `GravityPayment.pay`.
4. Wait for the receipt and surface `PaymentMade` metadata and gas usage.

### Observe Events
```ts
const payment = new ethers.Contract(address, abi, provider);
const events = await payment.queryFilter(payment.filters.PaymentMade());
```
`MNEESwapHook` exposes `TokenSwap` per hop for forensic analysis.

---

## Sepolia Playbook

Shared Uniswap v4 infrastructure:

| Contract | Address |
| --- | --- |
| PoolManager | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |
| PoolSwapTest | `0x9B6B46E2C869Aa39918DB7f52F5557fE577b6Eee` |
| PoolModifyLiquidityTest | `0x0C478023803A644c94C4cE1c1e7B9A087E411b0a` |
| Permit2 | `0x000000000022D473030F116dDEE9F6B43aC78BA3` |

1. `cd Gravity && cp .env.example .env`
2. Configure `RPC_URL`, `PRIVATE_KEY`, plus MNEE + Gravity contract addresses once deployed.
3. Deploy ERC20s and the Gravity stack referencing the Sepolia PoolManager.
4. Register tokens/pools via `registerToken`, `setIntermediateToken`, `registerPool`, and `setPoolExchangeRate`.
5. Seed liquidity through `PoolModifyLiquidityTest` and validate via `PoolSwapTest`.
6. Run `pnpm ts-node scripts/GravitySWAP.ts` and watch `PaymentMade` / `TokenSwap` to confirm settlement.

`docs/ARCHITECHTURE.md` provides the detailed architecture section referenced in audits and PRDs.

---

## Development Toolkit
- **Mocks** – `MockERC20` and `MockPoolManager` unblock deterministic integration tests.
- **Ignition module** – `npx hardhat ignition deploy --network <target> ignition/modules/Counter.ts` for template deployments.
- **Type generation** – `pnpm hardhat typechain` keeps Ethers.js typings current for TS scripts.
- **Linting** – plug in your preferred Solidity/TS linters (not bundled by default).

---

## Contributing
- Fork + open PRs with clear descriptions and tests.
- Keep `.env.example` and `docs/ARCHITECHTURE.md` in sync with infrastructure or logic changes.
- File issues for routing optimizations, new analytics hooks, or governance proposals.

Gravity Protocol is evolving—feedback on routing heuristics, risk controls, or UX is welcome.
