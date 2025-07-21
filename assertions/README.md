# Aave V3 Assertion Suite

We've taken a deep dive into the Aave V3 protocol and have created a suite of assertions that can be used to increase the security of the protocol.

In general, the Aave V3 smart contracts are very well written and follow best practices with regard to security.
We chose Aave V3 because it's a popular and battle-tested protocol that would serve as a good case study for writing real-world assertions.

Link to the Phylax fork of Aave V3: [https://github.com/phylaxsystems/aave-v3-origin/tree/main](https://github.com/phylaxsystems/aave-v3-origin/tree/main)

## Approach

One of the most common ways of writing assertions is by expressing the protocol invariants as assertions.

Aave V3 has put a lot of effort into invariants, as can be seen in the [Aave V3 Invariants](https://github.com/aave-dao/aave-v3-origin/tree/main/tests/invariants) documentation.
Specifically, the [invariants specification](https://github.com/aave-dao/aave-v3-origin/tree/main/tests/invariants/specs) was helpful for writing assertions, and most of the assertions we wrote are based on the invariants.

We have mocked parts of the protocol in order to properly test the assertions and ensure that they only revert transactions that break the invariants. The mocks are located in the [mocks](https://github.com/phylaxsystems/aave-v3-origin/tree/main/assertions/mocks) directory.

## Here Be Dragons

In order to showcase the real power of assertions, we have introduced a bug in the protocol.

Anyone borrowing exactly `333e6` tokens will receive double the amount of tokens they would normally receive if they borrowed any other amount.

The bug can be found in the [BorrowLogic.sol](https://github.com/phylaxsystems/aave-v3-origin/blob/main/src/protocol/libraries/logic/BorrowLogic.sol#L128-L144) file.

> [!Warning]
> DO NOT USE THIS VERSION OF AAVE V3 IN PRODUCTION!!!

## Key Features

- Protocol violation detection
- Comprehensive operation coverage (supply, borrow, repay, withdraw, liquidation, flash loans)
- Based on Aave's official invariants
- Assertion specific test suite

## Assertion Types

### Production Assertions (High Value)

These assertions provide unique value beyond pure Solidity capabilities:

- **Cross-transaction validation**: Verify invariants across multiple operations
- **Oracle security**: Detect price manipulation and consistency issues
- **Complex state relationships**: Validate accounting integrity
- **Proxy/delegatecall resilience**: Use event logs for robust verification

### Showcase Assertions (Demonstrative)

These demonstrate assertion capabilities but could be implemented in Solidity:

- **Basic balance validation**: Simple balance change checks
- **Health factor validation**: Standard health factor maintenance
- **Reserve state validation**: Basic reserve condition checks
- **Cap validation**: Supply/borrow cap enforcement

## Assertion Collections

### Production Assertions (High Value)

#### Core Invariants

- **[BaseInvariants](https://github.com/phylaxsystems/aave-v3-origin/blob/main/assertions/src/production/BaseInvariants.a.sol)** - Cross-transaction accounting validation:
  - Debt token supply consistency across operations
  - AToken supply consistency across operations
  - Underlying balance invariant validation
  - Virtual balance sanity checks
  - Liquidity index integrity verification

#### Oracle Security

> [!Note]
> For oracle assertions to be effective a new cheatcode is needed that allows for more granular call stack inspection so that we can check the price reported by the oracle at each call stack.
> This cheatcode is currently in the works and will be supported soon.

- **[OracleAssertions](https://github.com/phylaxsystems/aave-v3-origin/blob/main/assertions/src/production/OracleAssertions.a.sol)** - Price manipulation detection:
  - Borrow/supply/liquidation price deviation monitoring (5% max)
  - Price consistency validation across transactions
  - Oracle manipulation attack prevention

#### Flashloan Protection

- **[FlashloanInvariantAssertions](https://github.com/phylaxsystems/aave-v3-origin/blob/main/assertions/src/production/FlashloanInvariantAssertions.a.sol)** - Flashloan security:
  - Repayment verification (amount + fee)
  - Fee payment validation
  - Reserve state integrity

#### Robust Verification

- **[LogBasedAssertions](https://github.com/phylaxsystems/aave-v3-origin/blob/main/assertions/src/production/LogBasedAssertions.a.sol)** - Proxy/delegatecall resilient validation:
  - Balance change verification using event logs
  - Works with complex call patterns

### Showcase Assertions (Demonstrative)

#### Operation Validation

- **[BorrowingInvariantAssertions](https://github.com/phylaxsystems/aave-v3-origin/blob/main/assertions/src/showcase/BorrowingInvariantAssertions.a.sol)** - Standard borrow checks:
  - Liability decrease verification
  - Health factor maintenance
  - Reserve state consistency
  - Borrow cap enforcement
  - Balance/debt tracking

- **[LendingInvariantAssertions](https://github.com/phylaxsystems/aave-v3-origin/blob/main/assertions/src/showcase/LendingInvariantAssertions.a.sol)** - Standard supply/withdrawal checks:
  - Reserve state validation
  - Supply cap enforcement
  - Balance change verification
  - Collateral withdrawal health

- **[LiquidationInvariantAssertions](https://github.com/phylaxsystems/aave-v3-origin/blob/main/assertions/src/showcase/LiquidationInvariantAssertions.a.sol)** - Standard liquidation checks:
  - Health factor thresholds
  - Grace period validation
  - Close factor conditions
  - Deficit accounting
  - Reserve state requirements

#### Health Factor Management

- **[HealthFactorAssertions](https://github.com/phylaxsystems/aave-v3-origin/blob/main/assertions/src/showcase/HealthFactorAssertions.a.sol)** - Health factor transitions:
  - Non-decreasing health factor actions
  - Healthy to unhealthy transition prevention
  - Supply/withdraw/repay health maintenance

#### Basic Validation

- **[BorrowLogicErrorAssertion](https://github.com/phylaxsystems/aave-v3-origin/blob/main/assertions/src/showcase/BorrowLogicErrorAssertion.a.sol)** - Simple balance validation:
  - Borrow amount matches underlying balance change

## Testing

### Structure

- Positive tests: Valid operations pass
- Negative tests: Invalid operations fail
- Integration tests: Multi-operation sequences
- Edge cases: Boundary conditions

### Categories

- Individual operation tests
- Batch operation tests
- Error condition tests
- Mock protocol tests

## Intentional Bugs

1. **333e6 Borrow Bug**: Borrowing exactly 333e6 tokens returns double amount
   - Location: `BorrowLogic.sol` lines 128-144
   - Test: `test_BASE_INVARIANT_A_DebtTokenSupply_333e6Bug()`

2. **Mock Protocol**: `BrokenPool.sol` for controlled testing

## Usage

```bash
# Run all assertion tests
FOUNDRY_PROFILE=assertions pcl test

# Run specific test file
FOUNDRY_PROFILE=assertions pcl test assertions/test/BaseInvariants.t.sol
```
