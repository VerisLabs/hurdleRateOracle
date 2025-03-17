# Hurdle Rate Oracle

A Solidity smart contract that fetches and stores hurdle rates for multiple tokens using Chainlink Functions. The oracle uses an efficient bitmap storage pattern that allows scaling up to 16 different token rates without additional costs.

## Features

- Fetches and stores rates for up to 16 different tokens
- Uses Chainlink Functions for decentralized off-chain data fetching
- Efficient bitmap storage pattern for gas optimization
- Built-in rate update frequency limits to prevent manipulation
- Supports rate queries by token address or position
- Includes comprehensive security features and access controls

## Contract Details

The HurdleRateOracle contract includes:

- Rate updates via Chainlink Functions
- Rate storage in a bitmap format (16 bits per rate)
- Token registration system with fixed positions
- Rate query functions by token address or position
- Built-in security features:
  - ReentrancyGuard
  - ConfirmedOwner
  - Update frequency limits
  - Rate validation
  - Contract pause functionality

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/) (for deployment scripts)
- Access to a Chainlink Functions subscription
- Base network RPC URL

## Installation

1. Clone the repository:
```bash
git clone <repository-url>
cd hurdle-rate-oracle
```

2. Install dependencies:
```bash
forge install
```

## Testing

Run the test suite:

```bash
forge test
```

## Deployment

1. Set up environment variables:
```bash
cp .env.example .env
```

Edit `.env` with your configuration:
```
PRIVATE_KEY=your_private_key
RPC_URL=your_rpc_url
CHAINLINK_FUNCTIONS_SUBSCRIPTION_ID=your_subscription_id
```

2. Deploy the contract:
```bash
forge script script/DeployHurdleRateOracle.s.sol --rpc-url $RPC_URL --broadcast
```

## Usage

### Registering Tokens

```solidity
// Only owner can register tokens
function registerToken(address token, uint8 position) external onlyOwner
```

### Updating Rates

```solidity
// Anyone can trigger a rate update
function updateRates() external nonReentrant isNotPaused
```

### Querying Rates

```solidity
// Get rate for a specific token
function getRate(address token) external view returns (uint16 rate, uint256 timestamp)

// Get rate by position
function getRateByPosition(uint8 position) external view returns (uint16)

// Get all rates
function getAllRates() external view returns (uint256)
```

## Security Considerations

- Rate updates are limited to once per hour
- Maximum rate is capped at 100% (10000 basis points)
- Contract can be paused by owner in case of emergencies
- Uses ReentrancyGuard for all state-modifying functions
- Comprehensive input validation

## License

MIT License

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.
