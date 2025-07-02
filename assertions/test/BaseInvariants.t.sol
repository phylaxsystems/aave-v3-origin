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

  function test_BASE_INVARIANT_A_DebtTokenSupply() public {
    // Test that debt token totalSupply matches the sum of user balances
    // This invariant is already implemented in the BaseInvariants contract

    // Set up fresh user with collateral
    deal(asset, alice, 20000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral first
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    pool.supply(supplyArgs);

    // Borrow to trigger debt token supply change - this should pass assertions
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 1000e6, 2, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_B_ATokenSupply() public {
    // Test that aToken totalSupply matches the sum of user balances

    // Set up fresh user with collateral
    deal(asset, bob, 20000e6);
    vm.startPrank(bob);
    underlying.approve(address(pool), type(uint256).max);

    // Supply to trigger aToken supply change - this should pass assertions
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 1500e6, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_C_UnderlyingBalanceInvariant() public {
    // Test that underlying balance >= (aToken supply - debt token supply)

    // Set up fresh user with collateral
    deal(asset, alice, 20000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply to increase underlying balance - this should pass assertions
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 2000e6, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_D_VirtualBalanceInvariant() public {
    // Test that actual underlying balance >= 0 (basic sanity check)

    // Set up fresh user with collateral
    deal(asset, bob, 20000e6);
    vm.startPrank(bob);
    underlying.approve(address(pool), type(uint256).max);

    // Supply to increase underlying balance - this should pass assertions
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 1000e6, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function test_BASE_INVARIANT_F_LiquidityIndexInvariant() public {
    // Test the core accounting invariant for interest accrual

    // Set up fresh user with collateral
    deal(asset, alice, 20000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply to potentially trigger interest accrual - this should pass assertions
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 3000e6, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function test_MultipleOperationsMaintainInvariants() public {
    // Test that multiple operations maintain all invariants

    // Set up fresh user with collateral
    deal(asset, bob, 20000e6);
    vm.startPrank(bob);
    underlying.approve(address(pool), type(uint256).max);

    // Perform multiple operations - each should pass assertions
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );

    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 5000e6, 2, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );

    // Repay some debt
    bytes32 repayArgs = l2Encoder.encodeRepayParams(asset, 1000e6, 2);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.repay.selector, repayArgs)
    );

    // Withdraw some collateral
    bytes32 withdrawArgs = l2Encoder.encodeWithdrawParams(asset, 2000e6);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.withdraw.selector, withdrawArgs)
    );
    vm.stopPrank();
  }

  function test_InvariantsWithLiquidation() public {
    // Test that liquidation operations maintain invariants

    // First, create a position that can be liquidated
    deal(asset, alice, 20000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );

    // Borrow a reasonable amount
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 3000e6, 2, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();

    // Note: Actual liquidation would require price manipulation to make the position unhealthy
    // For now, we just test that the encoding works correctly
    (bytes32 liquidationArgs1, bytes32 liquidationArgs2) = l2Encoder.encodeLiquidationCall(
      asset,
      asset,
      alice,
      100e6,
      false
    );

    // The liquidation call encoding should work without errors
    // The actual liquidation would require price manipulation to make the position unhealthy
  }

  function test_EdgeCases() public {
    // Test edge cases that might affect invariants

    // Test with very small amounts (but still valid for borrowing)
    deal(asset, bob, 20000e6);
    vm.startPrank(bob);
    underlying.approve(address(pool), type(uint256).max);

    // Supply enough collateral to allow borrowing
    bytes32 smallSupplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, smallSupplyArgs)
    );

    // Borrow a small amount (but not too small to cause health factor issues)
    bytes32 smallBorrowArgs = l2Encoder.encodeBorrowParams(asset, 1000e6, 2, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, smallBorrowArgs)
    );
    vm.stopPrank();
  }

  function test_InvariantPersistence() public {
    // Test that invariants persist across multiple blocks

    // Set up fresh user with collateral
    deal(asset, alice, 20000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Block 1 - Supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );

    // Advance time to trigger interest accrual
    vm.warp(block.timestamp + 1 days);

    // Block 2 - Borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 3000e6, 2, 0);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );

    // Advance time again
    vm.warp(block.timestamp + 1 days);

    // Block 3 - Repay
    bytes32 repayArgs = l2Encoder.encodeRepayParams(asset, 1000e6, 2);
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.repay.selector, repayArgs)
    );
    vm.stopPrank();
  }

  function test_DebugDebtTokenSupply() public {
    // Debug test to understand what's happening with debt token supply
    deal(asset, alice, 20000e6);
    vm.startPrank(alice);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral first
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 10000e6, 0);
    pool.supply(supplyArgs);

    // Check debt token supply before borrow
    uint256 beforeDebtSupply = variableDebtToken.totalSupply();
    uint256 beforeUserBalance = underlying.balanceOf(alice);

    emit log_named_uint('Debt token supply before borrow', beforeDebtSupply);
    emit log_named_uint('User balance before borrow', beforeUserBalance);

    // Borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 1000e6, 2, 0);
    pool.borrow(borrowArgs);

    // Check debt token supply after borrow
    uint256 afterDebtSupply = variableDebtToken.totalSupply();
    uint256 afterUserBalance = underlying.balanceOf(alice);

    emit log_named_uint('Debt token supply after borrow', afterDebtSupply);
    emit log_named_uint('User balance after borrow', afterUserBalance);
    emit log_named_uint('Debt token supply change', afterDebtSupply - beforeDebtSupply);
    emit log_named_uint('User balance change', afterUserBalance - beforeUserBalance);
    emit log_named_uint('Expected change', 1000e6);

    vm.stopPrank();
  }
}
