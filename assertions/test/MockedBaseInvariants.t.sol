// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title MockedBaseInvariants Tests
 * @notice This test file uses a mocked version of the Aave V3 protocol to verify that
 *         our BaseInvariants assertions correctly revert when the protocol violates our invariants.
 *         It ensures that our high-value assertions actually catch and prevent invalid state
 *         changes that could compromise protocol security.
 *
 *         The mock pool is located in assertions/mocks/BrokenPool.sol
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {BaseInvariants} from '../src/production/BaseInvariants.a.sol';
import {IMockL2Pool} from '../src/interfaces/IMockL2Pool.sol';
import {BrokenPool} from '../mocks/BrokenPool.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {L2Encoder} from '../../src/contracts/helpers/L2Encoder.sol';
import {IPool} from '../../src/contracts/interfaces/IPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {MockERC20} from '../mocks/MockERC20.sol';

contract MockedBaseInvariantsTest is CredibleTest, Test {
  IMockL2Pool public pool;
  BaseInvariants public baseInvariants;
  L2Encoder public l2Encoder;
  address public user;
  address public asset;
  address public aToken;
  address public variableDebtToken;
  IERC20 public underlying;
  MockERC20 public mockAToken;
  MockERC20 public mockDebtToken;
  MockERC20 public mockUnderlying;
  string public constant ASSERTION_LABEL = 'BaseInvariants';

  function setUp() public {
    // Deploy mock pool
    pool = IMockL2Pool(address(new BrokenPool()));

    // Set up user and asset
    user = address(0x1);
    asset = address(0x2);

    // Create mock tokens through BrokenPool
    BrokenPool(address(pool)).createMockTokens(asset);

    // Get token addresses from BrokenPool
    aToken = BrokenPool(address(pool)).aTokenAddresses(asset);
    variableDebtToken = BrokenPool(address(pool)).variableDebtTokenAddresses(asset);

    // Get the mock underlying token from BrokenPool
    mockUnderlying = BrokenPool(address(pool)).getMockUnderlying(asset);
    underlying = IERC20(address(mockUnderlying));

    // Set up L2Encoder for creating compact parameters
    l2Encoder = new L2Encoder(IPool(address(pool)));

    // Configure mock pool
    BrokenPool(address(pool)).setActive(asset, true);
    BrokenPool(address(pool)).setFrozen(asset, false);
    BrokenPool(address(pool)).setPaused(asset, false);

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

  function testAssertionDebtTokenSupplyFailure_Borrow() public {
    // Configure mock to break debt token supply invariant
    BrokenPool(address(pool)).setBreakDebtTokenSupply(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 100e6, 2, 0);

    // Set debt token supply to a value that doesn't match what the borrow operation will create
    // The borrow operation will increase user debt by 100e6, but we'll set the debt token supply
    // to a different value, violating the invariant
    BrokenPool(address(pool)).manipulateDebtTokenSupply(asset, 50e6); // Should be 100e6 to match user debt

    // This should revert because the debt token supply doesn't match the calculated debt changes
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function testAssertionDebtTokenSupplyFailure_Repay() public {
    // Configure mock to break debt token supply invariant
    BrokenPool(address(pool)).setBreakDebtTokenSupply(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for repay
    bytes32 repayArgs = l2Encoder.encodeRepayParams(asset, 50e6, 2);

    // Set debt token supply to a value that doesn't match what the repay operation will create
    // The repay operation will decrease user debt by 50e6, but we'll set the debt token supply
    // to a different value, violating the invariant
    BrokenPool(address(pool)).manipulateDebtTokenSupply(asset, 100e6); // Should be 50e6 to match user debt

    // This should revert because the debt token supply doesn't match the calculated debt changes
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.repay.selector, repayArgs)
    );
    vm.stopPrank();
  }

  function testAssertionDebtTokenSupplyFailure_Liquidation() public {
    // Configure mock to break debt token supply invariant
    BrokenPool(address(pool)).setBreakDebtTokenSupply(true);

    // Set up user with debt first (this is needed for liquidation to work)
    BrokenPool(address(pool)).setUserDebt(user, 100e6); // User has 100e6 debt

    // Set initial debt token supply to match user debt
    BrokenPool(address(pool)).manipulateDebtTokenSupply(asset, 100e6); // Initial debt token supply

    // Set user as the caller
    vm.startPrank(user);

    // Use L2Encoder to encode liquidation call arguments
    (bytes32 liquidationArgs1, bytes32 liquidationArgs2) = l2Encoder.encodeLiquidationCall(
      address(0x1), // collateral asset (maps to asset ID 1 in BrokenPool)
      asset, // debt asset (maps to asset ID 2 in BrokenPool)
      user,
      30e6, // debt to cover
      false // receive aToken
    );

    // The liquidation operation should decrease debt by 30e6 (from 100e6 to 70e6)
    // But since breakDebtTokenSupply is true, the user debt will decrease but the debt token supply won't
    // The assertion expects the debt token supply to decrease by 30e6, but it will stay at 100e6
    // This creates a violation: calculated change (-30e6) != actual change (0)

    // This should revert because the debt token supply doesn't match the calculated debt changes
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(
        IMockL2Pool.liquidationCall.selector,
        liquidationArgs1,
        liquidationArgs2
      )
    );
    vm.stopPrank();
  }

  // ============================================================================
  // BASE_INVARIANT_B: AToken Supply Tests
  // ============================================================================

  function testAssertionATokenSupplyFailure_Supply() public {
    // Configure mock to break aToken supply invariant
    BrokenPool(address(pool)).setBreakATokenSupply(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 100e6, 0);

    // This should revert because the aToken supply doesn't match the calculated balance changes
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  // ============================================================================
  // BASE_INVARIANT_C: Underlying Balance Invariant Tests
  // ============================================================================

  function testAssertionUnderlyingBalanceInvariantFailure_Supply() public {
    // Configure mock to break underlying balance invariant
    BrokenPool(address(pool)).setBreakUnderlyingBalance(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 100e6, 0);

    // This should revert because the underlying balance doesn't match the aToken supply
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function testAssertionUnderlyingBalanceInvariantFailure_Borrow() public {
    // Configure mock to break underlying balance invariant
    BrokenPool(address(pool)).setBreakUnderlyingBalance(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 100e6, 2, 0);

    // This should revert because the underlying balance doesn't match the aToken supply
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  // ============================================================================
  // BASE_INVARIANT_D: Virtual Balance Invariant Tests
  // ============================================================================

  function testAssertionVirtualBalanceInvariantFailure_Supply() public {
    // Configure mock to break virtual balance invariant
    BrokenPool(address(pool)).setBreakVirtualBalance(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 100e6, 0);

    // This should revert because the virtual balance invariant is violated
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function testAssertionVirtualBalanceInvariantFailure_Borrow() public {
    // Configure mock to break virtual balance invariant
    BrokenPool(address(pool)).setBreakVirtualBalance(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 100e6, 2, 0);

    // This should revert because the virtual balance invariant is violated
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  // ============================================================================
  // BASE_INVARIANT_F: Liquidity Index Invariant Tests
  // ============================================================================

  function testAssertionLiquidityIndexInvariantFailure_Supply() public {
    // Configure mock to break liquidity index invariant
    BrokenPool(address(pool)).setBreakLiquidityIndex(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 100e6, 0);

    // Set liquidity index to 0, which violates the invariant that it should be >= 1e27
    BrokenPool(address(pool)).setLiquidityIndex(asset, 0);

    // This should revert because the liquidity index is invalid
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function testAssertionLiquidityIndexInvariantFailure_Borrow() public {
    // Configure mock to break liquidity index invariant
    BrokenPool(address(pool)).setBreakLiquidityIndex(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 100e6, 2, 0);

    // Set liquidity index to 0, which violates the invariant that it should be >= 1e27
    BrokenPool(address(pool)).setLiquidityIndex(asset, 0);

    // This should revert because the liquidity index is invalid
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  // ============================================================================
  // Edge Cases and Stress Tests
  // ============================================================================

  function testAssertionDebtTokenSupplyFailure_ZeroAmount() public {
    // Configure mock to break debt token supply invariant
    BrokenPool(address(pool)).setBreakDebtTokenSupply(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for borrow with zero amount
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 0, 2, 0);

    // Set debt token supply to a non-zero value when borrow amount is zero
    BrokenPool(address(pool)).manipulateDebtTokenSupply(asset, 100e6);

    // This should revert because the debt token supply doesn't match the calculated debt changes
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  function testAssertionATokenSupplyFailure_ZeroAmount() public {
    // Configure mock to break aToken supply invariant
    BrokenPool(address(pool)).setBreakATokenSupply(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for supply with zero amount
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 0, 0);

    // This should revert because the aToken supply doesn't match the calculated balance changes
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function testAssertionLiquidityIndexInvariantFailure_InvalidIndex() public {
    // Configure mock to break liquidity index invariant
    BrokenPool(address(pool)).setBreakLiquidityIndex(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 100e6, 0);

    // Set liquidity index to a very large value that would cause overflow
    BrokenPool(address(pool)).setLiquidityIndex(asset, type(uint256).max);

    // This should revert because the liquidity index is invalid
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function testAssertionUnderlyingBalanceInvariantFailure_NegativeBalance() public {
    // Configure mock to break underlying balance invariant
    BrokenPool(address(pool)).setBreakUnderlyingBalance(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 100e6, 0);

    // Set underlying balance to 0 while aToken supply is high, violating the invariant
    // The invariant requires: underlying balance >= (aToken supply - debt token supply)
    BrokenPool(address(pool)).manipulateATokenSupply(asset, 1000e6); // High aToken supply
    BrokenPool(address(pool)).manipulateDebtTokenSupply(asset, 100e6); // Low debt token supply
    BrokenPool(address(pool)).manipulateUnderlyingBalance(asset, 0); // Zero underlying balance

    // This should revert because the underlying balance is insufficient
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  // ============================================================================
  // Multiple Violation Tests
  // ============================================================================

  function testMultipleInvariantViolations() public {
    // Configure mock to break multiple invariants simultaneously
    BrokenPool(address(pool)).setBreakDebtTokenSupply(true);
    BrokenPool(address(pool)).setBreakATokenSupply(true);
    BrokenPool(address(pool)).setBreakUnderlyingBalance(true);
    BrokenPool(address(pool)).setBreakLiquidityIndex(true);

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 100e6, 2, 0);

    // Set various token supplies to violate multiple invariants
    BrokenPool(address(pool)).manipulateDebtTokenSupply(asset, 50e6);
    BrokenPool(address(pool)).manipulateATokenSupply(asset, 1000e6);
    BrokenPool(address(pool)).manipulateUnderlyingBalance(asset, 0);
    BrokenPool(address(pool)).setLiquidityIndex(asset, 0);

    // This should revert because multiple invariants are violated
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(IMockL2Pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  // ============================================================================
  // Helper function to set up user balances in BrokenPool
  // ============================================================================
  function setupUserBalances(address _user, address _asset, uint256 amount) internal {
    // This would need to be implemented in BrokenPool if not already available
    // For now, we'll use the existing setUserDebt function
  }
}
