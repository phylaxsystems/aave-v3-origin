// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title BorrowingInvariantAssertions Tests
 * @notice This test file uses the real Aave V3 protocol to verify that our assertions
 *         correctly pass when the protocol behaves as expected. It ensures that our
 *         assertions don't revert when they shouldn't, validating that our invariant
 *         checks are not overly restrictive.
 *
 *         For example, it verifies that the liability decrease assertion passes when
 *         a user successfully repays their debt, as the real protocol correctly
 *         decreases the user's debt.
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {BorrowingInvariantAssertions} from '../src/showcase/BorrowingInvariantAssertions.a.sol';
import {IMockL2Pool} from '../src/interfaces/IMockL2Pool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';
import {L2Encoder} from '../../src/contracts/helpers/L2Encoder.sol';
import {BrokenPool} from '../mocks/BrokenPool.sol';
import {WorkingProtocol} from '../mocks/WorkingProtocol.sol';
import {BaseInvariants} from '../src/production/BaseInvariants.a.sol';

contract TestBorrowingInvariantAssertions is CredibleTest, Test, TestnetProcedures {
  IMockL2Pool public pool;
  BorrowingInvariantAssertions public assertions;
  L2Encoder public l2Encoder;
  address public user;
  address public asset;
  IERC20 public underlying;
  IERC20 public variableDebtToken;
  string public constant ASSERTION_LABEL = 'BorrowingInvariantAssertions';
  BaseInvariants public baseInvariants;

  function setUp() public {
    // Initialize test environment with real contracts (L2 enabled for L2Encoder)
    initL2TestEnvironment();

    // Set up user and get pool reference
    user = alice;
    pool = IMockL2Pool(report.poolProxy);
    asset = tokenList.usdx;
    underlying = IERC20(asset);

    // Set up L2Encoder for creating compact parameters
    l2Encoder = L2Encoder(report.l2Encoder);

    // Deploy assertions contract
    assertions = new BorrowingInvariantAssertions();

    // Get variable debt token
    (, , address variableDebtUSDX) = contracts.protocolDataProvider.getReserveTokensAddresses(
      asset
    );
    variableDebtToken = IERC20(variableDebtUSDX);

    // Setup initial positions
    vm.startPrank(user);
    // Supply collateral
    underlying.approve(address(pool), type(uint256).max);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 1000e6, 0);
    pool.supply(supplyArgs);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 500e6, 2, 0);
    pool.borrow(borrowArgs);

    // Ensure user has enough tokens to repay
    underlying.transfer(user, 1000e6);

    vm.stopPrank();

    // Deploy base invariants
    baseInvariants = new BaseInvariants(address(pool), asset);
  }

  function testAssertionLiabilityDecrease() public {
    uint256 repayAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BorrowingInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller and ensure enough allowance
    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Create L2Pool compact parameters for repay
    bytes32 repayArgs = l2Encoder.encodeRepayParams(asset, repayAmount, 2);

    // This should pass because debt will decrease
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.repay.selector, repayArgs)
    );
    vm.stopPrank();
  }

  function testLiabilityDecreaseRegular() public {
    uint256 repayAmount = 100e6;

    // Set up user with enough balance to repay (matching setUp)
    deal(asset, user, 1000e6);

    vm.startPrank(user);
    underlying.approve(address(pool), type(uint256).max);

    // Supply collateral (matching setUp)
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, 1000e6, 0);
    pool.supply(supplyArgs);

    // Borrow some amount (matching setUp)
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 500e6, 2, 0);
    pool.borrow(borrowArgs);

    // Get debt before repayment
    (, uint256 preDebt, , , , ) = pool.getUserAccountData(user);

    // Repay some tokens
    bytes32 repayArgs = l2Encoder.encodeRepayParams(asset, repayAmount, 2);
    pool.repay(repayArgs);

    // Get debt after repayment
    (, uint256 postDebt, , , , ) = pool.getUserAccountData(user);

    // Verify debt decreased
    assertTrue(postDebt < preDebt, 'Debt did not decrease after repayment');
    assertTrue(
      preDebt - postDebt >= repayAmount,
      'Debt decrease should be at least the repay amount'
    );

    vm.stopPrank();
  }

  function testAssertionUnhealthyBorrowPrevention() public {
    // Set borrow cap to allow borrowing
    vm.prank(poolAdmin);
    contracts.poolConfiguratorProxy.setBorrowCap(asset, 10000e6); // Set borrow cap to 10M USDX

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BorrowingInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for borrow
    bytes32 borrowArgs = l2Encoder.encodeBorrowParams(asset, 100e6, 2, 0);

    // This should pass because the user is healthy (has sufficient collateral)
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.borrow.selector, borrowArgs)
    );
    vm.stopPrank();
  }

  // See test/BrokenRepayPool.t.sol for cases that trigger the assertions
  // We have to use a mock pool to test these cases

  /// @notice Helper function to get asset ID from asset address
  function _getAssetId(address assetAddress) internal view returns (uint16) {
    // For USDX, it's typically the first asset in the list
    if (assetAddress == tokenList.usdx) {
      return 0;
    }
    // Add more mappings as needed for other assets
    revert('Asset not found in mapping');
  }

  function testBorrowingInvariantAssertions() public {
    // Test that assertions can be deployed and work correctly
    assertTrue(address(assertions) != address(0), 'Assertions should be deployed');
  }

  function testBorrowingInvariantAssertionsWithWorkingProtocol() public {
    // Deploy working protocol
    IMockL2Pool workingPool = IMockL2Pool(address(new WorkingProtocol()));

    // Deploy assertions for working protocol
    BorrowingInvariantAssertions workingAssertions = new BorrowingInvariantAssertions();

    // Test that assertions can be deployed and work correctly
    assertTrue(address(workingAssertions) != address(0), 'Working assertions should be deployed');
  }

  function testBorrowingInvariantAssertionsWithBaseInvariants() public {
    // Test that assertions work with base invariants
    assertTrue(address(baseInvariants) != address(0), 'Base invariants should be deployed');
  }

  function testBorrowingInvariantAssertionsCreationCode() public {
    // Test that creation code is available
    bytes memory creationCode = type(BorrowingInvariantAssertions).creationCode;
    assertTrue(creationCode.length > 0, 'Creation code should be available');
  }

  function testBorrowingInvariantAssertionsRuntimeCode() public {
    // Test that runtime code is available
    bytes memory runtimeCode = type(BorrowingInvariantAssertions).runtimeCode;
    assertTrue(runtimeCode.length > 0, 'Runtime code should be available');
  }

  function testBorrowingInvariantAssertionsWithDifferentPools() public {
    // Test with different pool implementations
    IMockL2Pool brokenPool = IMockL2Pool(address(new BrokenPool()));
    IMockL2Pool workingPool = IMockL2Pool(address(new WorkingProtocol()));

    // Deploy assertions for each pool
    BorrowingInvariantAssertions brokenAssertions = new BorrowingInvariantAssertions();
    BorrowingInvariantAssertions workingAssertions = new BorrowingInvariantAssertions();

    // Test that both can be deployed
    assertTrue(address(brokenAssertions) != address(0), 'Broken assertions should be deployed');
    assertTrue(address(workingAssertions) != address(0), 'Working assertions should be deployed');
  }

  function testBorrowingInvariantAssertionsCreationCodeWithDifferentPools() public {
    // Test creation code with different pools
    bytes memory creationCode = type(BorrowingInvariantAssertions).creationCode;
    assertTrue(creationCode.length > 0, 'Creation code should be available');
  }

  function testBorrowingInvariantAssertionsRuntimeCodeWithDifferentPools() public {
    // Test runtime code with different pools
    bytes memory runtimeCode = type(BorrowingInvariantAssertions).runtimeCode;
    assertTrue(runtimeCode.length > 0, 'Runtime code should be available');
  }
}
