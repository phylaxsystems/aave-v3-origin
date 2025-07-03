// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {Test} from 'forge-std/Test.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {BaseInvariants} from '../src/production/BaseInvariants.a.sol';
import {IMockL2Pool} from '../src/interfaces/IMockL2Pool.sol';
import {L2Encoder} from '../../src/contracts/helpers/L2Encoder.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';

/**
 * @title BaseInvariantsTest
 * @notice Tests for the base protocol invariants using proper assertion testing
 */
contract BaseInvariantsTest is CredibleTest, Test, TestnetProcedures {
  IMockL2Pool public pool;
  L2Encoder public l2Encoder;
  address public asset;
  IERC20 public underlying;
  IERC20 public aToken;
  IERC20 public variableDebtToken;
  BaseInvariants public baseInvariants;
  string public constant ASSERTION_LABEL = 'BaseInvariants';

  function setUp() public {
    // Initialize test environment with real contracts (L2 enabled for L2Encoder)
    initL2TestEnvironment();

    // Deploy mock token
    asset = tokenList.usdx;
    underlying = IERC20(asset);

    // Get protocol tokens
    (, address aTokenUSDX, address variableDebtUSDX) = contracts
      .protocolDataProvider
      .getReserveTokensAddresses(asset);
    aToken = IERC20(aTokenUSDX);
    variableDebtToken = IERC20(variableDebtUSDX);

    // Set up pool reference
    pool = IMockL2Pool(report.poolProxy);

    // Set up L2Encoder for creating compact parameters
    l2Encoder = L2Encoder(report.l2Encoder);

    // Deploy base invariants contract
    baseInvariants = new BaseInvariants(address(pool), asset);

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BaseInvariants).creationCode,
      abi.encode(address(pool), asset)
    );
  }

  // ============================================================================
  // BASE_INVARIANT_A: Debt Token Supply Tests
  // ============================================================================
  // Tests that debt token totalSupply matches the sum of user balances
  // Operations that affect debt token supply: borrow, repay, liquidation

  function test_BASE_INVARIANT_A_DebtTokenSupply_Borrow() public {
    // Test debt token supply invariant with borrow operation
    deal(asset, alice, 50000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral first
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 20000e6, 0);
    pool.supply(supplyArgs);

    // Borrow to trigger debt token supply change
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 5000e6, 2, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_A_DebtTokenSupply_Repay() public {
    // Test debt token supply invariant with repay operation
    deal(asset, alice, 50000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral and borrow
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 20000e6, 0);
    pool.supply(supplyArgs);

    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 5000e6, 2, 0);
    pool.borrow(borrowArgs);

    // Repay to trigger debt token supply change
    bytes32 repayArgs = l2Encoder.encodeRepayParams(asset, 2000e6, 2);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.repay.selector, repayArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_A_DebtTokenSupply_Liquidation() public {
    // Test debt token supply invariant with liquidation operation
    // TODO: This test requires price manipulation to create unhealthy positions
    // Need to implement: _borrowToBeBelowHf() helper and price manipulation via stdstore
    // See tests/protocol/pool/Pool.Liquidations.t.sol for reference implementation
    require(
      false,
      'TODO: Liquidation test needs price manipulation implementation - see Pool.Liquidations.t.sol for reference'
    );
  }

  // ============================================================================
  // BASE_INVARIANT_B: AToken Supply Tests
  // ============================================================================
  // Tests that aToken totalSupply matches the sum of user balances
  // Operations that affect aToken supply: supply, withdraw, liquidation

  function test_BASE_INVARIANT_B_ATokenSupply_Supply() public {
    // Test aToken supply invariant with supply operation
    deal(asset, bob, 50000e6);
    vm.startPrank(bob);
    underlying.approve(address(pool), type(uint256).max);

    // Supply to trigger aToken supply change
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_B_ATokenSupply_Withdraw() public {
    // Test aToken supply invariant with withdraw operation
    deal(asset, bob, 50000e6);
    vm.startPrank(bob);
    underlying.approve(address(pool), type(uint256).max);

    // First supply to have something to withdraw
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 15000e6, 0);
    pool.supply(supplyArgs);

    // Withdraw to trigger aToken supply change
    bytes32 withdrawArgs = l2Encoder.encodeWithdrawParams(asset, 5000e6);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.withdraw.selector, withdrawArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_B_ATokenSupply_Liquidation() public {
    // Test aToken supply invariant with liquidation operation
    // TODO: This test requires price manipulation to create unhealthy positions
    // Need to implement: _borrowToBeBelowHf() helper and price manipulation via stdstore
    // See tests/protocol/pool/Pool.Liquidations.t.sol for reference implementation
    require(
      false,
      'TODO: Liquidation test needs price manipulation implementation - see Pool.Liquidations.t.sol for reference'
    );
  }

  // ============================================================================
  // BASE_INVARIANT_C: Underlying Balance Invariant Tests
  // ============================================================================
  // Tests that underlying balance >= (aToken supply - debt token supply)
  // Operations that affect underlying balance: supply, withdraw, borrow, repay, liquidation

  function test_BASE_INVARIANT_C_UnderlyingBalanceInvariant_Supply() public {
    // Test underlying balance invariant with supply operation
    deal(asset, alice, 50000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply to increase underlying balance
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_C_UnderlyingBalanceInvariant_Withdraw() public {
    // Test underlying balance invariant with withdraw operation
    deal(asset, bob, 50000e6);
    vm.startPrank(bob);
    underlying.approve(address(pool), type(uint256).max);

    // First supply to have something to withdraw
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 15000e6, 0);
    pool.supply(supplyArgs);

    // Withdraw to decrease underlying balance
    bytes32 withdrawArgs = l2Encoder.encodeWithdrawParams(asset, 5000e6);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.withdraw.selector, withdrawArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_C_UnderlyingBalanceInvariant_Borrow() public {
    // Test underlying balance invariant with borrow operation
    deal(asset, alice, 50000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral first
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 20000e6, 0);
    pool.supply(supplyArgs);

    // Borrow to decrease underlying balance
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 5000e6, 2, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_C_UnderlyingBalanceInvariant_Repay() public {
    // Test underlying balance invariant with repay operation
    deal(asset, alice, 50000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral and borrow
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 20000e6, 0);
    pool.supply(supplyArgs);

    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 5000e6, 2, 0);
    pool.borrow(borrowArgs);

    // Repay to increase underlying balance
    bytes32 repayArgs = l2Encoder.encodeRepayParams(asset, 2000e6, 2);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.repay.selector, repayArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_C_UnderlyingBalanceInvariant_Liquidation() public {
    // Test underlying balance invariant with liquidation operation
    // TODO: This test requires price manipulation to create unhealthy positions
    // Need to implement: _borrowToBeBelowHf() helper and price manipulation via stdstore
    // See tests/protocol/pool/Pool.Liquidations.t.sol for reference implementation
    require(
      false,
      'TODO: Liquidation test needs price manipulation implementation - see Pool.Liquidations.t.sol for reference'
    );
  }

  // ============================================================================
  // BASE_INVARIANT_D: Virtual Balance Invariant Tests
  // ============================================================================
  // Tests that actual underlying balance >= 0 (basic sanity check)
  // Operations that affect underlying balance: supply, withdraw, borrow, repay, liquidation

  function test_BASE_INVARIANT_D_VirtualBalanceInvariant_Supply() public {
    // Test virtual balance invariant with supply operation
    deal(asset, bob, 50000e6);
    vm.startPrank(bob);
    underlying.approve(address(pool), type(uint256).max);

    // Supply to increase underlying balance
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_D_VirtualBalanceInvariant_Withdraw() public {
    // Test virtual balance invariant with withdraw operation
    deal(asset, bob, 50000e6);
    vm.startPrank(bob);
    underlying.approve(address(pool), type(uint256).max);

    // First supply to have something to withdraw
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 15000e6, 0);
    pool.supply(supplyArgs);

    // Withdraw to decrease underlying balance
    bytes32 withdrawArgs = l2Encoder.encodeWithdrawParams(asset, 5000e6);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.withdraw.selector, withdrawArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_D_VirtualBalanceInvariant_Borrow() public {
    // Test virtual balance invariant with borrow operation
    deal(asset, alice, 50000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral first
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 20000e6, 0);
    pool.supply(supplyArgs);

    // Borrow to decrease underlying balance
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 5000e6, 2, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_D_VirtualBalanceInvariant_Repay() public {
    // Test virtual balance invariant with repay operation
    deal(asset, alice, 50000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral and borrow
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 20000e6, 0);
    pool.supply(supplyArgs);

    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 5000e6, 2, 0);
    pool.borrow(borrowArgs);

    // Repay to increase underlying balance
    bytes32 repayArgs = l2Encoder.encodeRepayParams(asset, 2000e6, 2);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.repay.selector, repayArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_D_VirtualBalanceInvariant_Liquidation() public {
    // Test virtual balance invariant with liquidation operation
    // TODO: This test requires price manipulation to create unhealthy positions
    // Need to implement: _borrowToBeBelowHf() helper and price manipulation via stdstore
    // See tests/protocol/pool/Pool.Liquidations.t.sol for reference implementation
    require(
      false,
      'TODO: Liquidation test needs price manipulation implementation - see Pool.Liquidations.t.sol for reference'
    );
  }

  // ============================================================================
  // BASE_INVARIANT_F: Liquidity Index Invariant Tests
  // ============================================================================
  // Tests the core accounting invariant for interest accrual
  // Operations that can trigger interest accrual: supply, borrow, repay, withdraw

  function test_BASE_INVARIANT_F_LiquidityIndexInvariant_Supply() public {
    // Test liquidity index invariant with supply operation
    deal(asset, alice, 50000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply to potentially trigger interest accrual
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 15000e6, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_F_LiquidityIndexInvariant_Borrow() public {
    // Test liquidity index invariant with borrow operation
    deal(asset, alice, 50000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral first
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 20000e6, 0);
    pool.supply(supplyArgs);

    // Borrow to potentially trigger interest accrual
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 5000e6, 2, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_F_LiquidityIndexInvariant_Repay() public {
    // Test liquidity index invariant with repay operation
    deal(asset, alice, 50000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral and borrow
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 20000e6, 0);
    pool.supply(supplyArgs);

    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 5000e6, 2, 0);
    pool.borrow(borrowArgs);

    // Repay to potentially trigger interest accrual
    bytes32 repayArgs = l2Encoder.encodeRepayParams(asset, 2000e6, 2);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.repay.selector, repayArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_F_LiquidityIndexInvariant_Withdraw() public {
    // Test liquidity index invariant with withdraw operation
    deal(asset, bob, 50000e6);
    vm.startPrank(bob);
    underlying.approve(address(pool), type(uint256).max);

    // First supply to have something to withdraw
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 15000e6, 0);
    pool.supply(supplyArgs);

    // Withdraw to potentially trigger interest accrual
    bytes32 withdrawArgs = l2Encoder.encodeWithdrawParams(asset, 5000e6);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.withdraw.selector, withdrawArgs)
    );
    vm.stopPrank();
  }

  // ============================================================================
  // Integration Tests
  // ============================================================================
  function test_BatchOperationsMaintainInvariants() public {
    // Test that a batch of operations maintains all invariants
    // This test uses a contract with fallback to execute multiple operations in sequence

    // Set up user with sufficient funds
    deal(asset, alice, 100000e6);

    // Deploy the batch operations contract
    BatchOperations batcher = new BatchOperations(address(pool), asset, alice, l2Encoder);

    // Mint tokens to the batcher contract for operations
    uint256 totalNeeded = 500000e6; // Supply + borrow amounts
    deal(asset, address(batcher), totalNeeded);

    // Approve the pool from the batcher contract
    vm.prank(address(batcher));
    underlying.approve(address(pool), totalNeeded);

    // Set up user permissions for the pool (needed for borrow operations)
    vm.prank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Validate the assertion by calling the batcher (which triggers fallback)
    // This will execute multiple operations in sequence and validate invariants
    vm.prank(alice);
    cl.validate(
      ASSERTION_LABEL,
      address(batcher),
      0,
      '' // fallback, so empty calldata
    );
  }

  function test_SupplyBatchOperationsMaintainInvariants() public {
    // Test that a batch of supply operations maintains all invariants
    // This test uses a contract with fallback to execute multiple supply operations in sequence

    // Note: We only batch supply operations because:
    // 1. Supply operations make sense to batch (users often want to supply different amounts)
    // 2. Borrow/repay/withdraw operations require specific user permissions and state conditions
    // 3. Mixing different operation types in one transaction is unrealistic and error-prone

    // Set up user with sufficient funds for initial supply
    deal(asset, alice, 100000e6);

    // Deploy the invariant batch operations contract
    InvariantBatchOperations batcher = new InvariantBatchOperations(
      address(pool),
      asset,
      alice,
      l2Encoder
    );

    // Mint tokens to the batcher contract for additional supply operations
    uint256 totalNeeded = 100000e6; // For additional supply operations
    deal(asset, address(batcher), totalNeeded);

    // Approve the pool from the batcher contract
    vm.prank(address(batcher));
    underlying.approve(address(pool), totalNeeded);

    // Set up user permissions for the pool (needed for borrow operations)
    vm.prank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Validate the assertion by calling the batcher (which triggers fallback)
    // This will execute multiple supply operations in sequence and validate invariants
    vm.prank(alice);
    cl.validate(
      ASSERTION_LABEL,
      address(batcher),
      0,
      '' // fallback, so empty calldata
    );
  }
}

// ============================================================================
// Batch Operations Contract
// ============================================================================

contract BatchOperations {
  IMockL2Pool public pool;
  address public asset;
  address public user;
  L2Encoder public l2Encoder;
  IERC20 public underlying;

  constructor(address pool_, address asset_, address user_, L2Encoder l2Encoder_) {
    pool = IMockL2Pool(pool_);
    asset = asset_;
    user = user_;
    l2Encoder = l2Encoder_;
    underlying = IERC20(asset_);
  }

  // Fallback to perform a batch of operations using L2Pool
  // This simulates a realistic sequence of operations that should maintain invariants
  fallback() external {
    // Step 1: Supply collateral
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 20000e6, 0);
    pool.supply(supplyArgs);

    // Step 2: Borrow against the collateral
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 8000e6, 2, 0);
    pool.borrow(borrowArgs);

    // Step 3: Supply more collateral
    bytes32 supplyArgs2 = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    pool.supply(supplyArgs2);

    // Step 4: Repay some debt
    bytes32 repayArgs = l2Encoder.encodeRepayParams(asset, 3000e6, 2);
    pool.repay(repayArgs);

    // Step 5: Withdraw some collateral
    bytes32 withdrawArgs = l2Encoder.encodeWithdrawParams(asset, 5000e6);
    pool.withdraw(withdrawArgs);

    // Step 6: Borrow a bit more
    bytes32 borrowArgs2 = l2Encoder.encodeBorrowParams(asset, 2000e6, 2, 0);
    pool.borrow(borrowArgs2);
  }
}

contract InvariantBatchOperations {
  IMockL2Pool public pool;
  address public asset;
  address public user;
  L2Encoder public l2Encoder;
  IERC20 public underlying;

  constructor(address pool_, address asset_, address user_, L2Encoder l2Encoder_) {
    pool = IMockL2Pool(pool_);
    asset = asset_;
    user = user_;
    l2Encoder = l2Encoder_;
    underlying = IERC20(asset_);
  }

  // Fallback to perform a batch of supply operations using L2Pool
  // This simulates a realistic batch of supply operations that should maintain invariants
  // Note: We only batch supply operations as they make sense to batch together
  fallback() external {
    // Supply operation 1: Large initial supply
    bytes32 supplyArgs1 = l2Encoder.encodeSupplyParams(asset, 30000e6, 0);
    pool.supply(supplyArgs1);

    // Supply operation 2: Medium additional supply
    bytes32 supplyArgs2 = l2Encoder.encodeSupplyParams(asset, 15000e6, 0);
    pool.supply(supplyArgs2);

    // Supply operation 3: Small additional supply
    bytes32 supplyArgs3 = l2Encoder.encodeSupplyParams(asset, 5000e6, 0);
    pool.supply(supplyArgs3);

    // Supply operation 4: Another medium supply
    bytes32 supplyArgs4 = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    pool.supply(supplyArgs4);
  }
}
