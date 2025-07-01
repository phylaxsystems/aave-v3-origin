// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title LiquidationInvariantAssertions Tests
 * @notice This test file uses a mocked protocol (WorkingProtocol) to verify that our assertions
 *         correctly pass when the protocol behaves as expected. We use a mock instead of the
 *         real Aave V3 protocol for simplicity, as setting up the full protocol suite and
 *         manipulating oracle prices would be time-consuming and more appropriate for thorough
 *         integration testing.
 *
 *         The mock protocol implements the core liquidation functionality needed to test our
 *         assertions, allowing us to focus on verifying that our invariant checks correctly
 *         validate expected protocol behavior.
 *
 *         For example, it verifies that the health factor threshold assertion passes when
 *         a user's position is unhealthy and can be liquidated, as the protocol correctly
 *         enforces the health factor requirements.
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {LiquidationInvariantAssertions} from '../src/LiquidationInvariantAssertions.a.sol';
import {IMockL2Pool} from '../src/IMockL2Pool.sol';
import {WorkingProtocol} from '../mocks/WorkingProtocol.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';
import {IAaveOracle} from '../../src/contracts/interfaces/IAaveOracle.sol';
import {LiquidationDataProvider} from '../../src/contracts/helpers/LiquidationDataProvider.sol';

contract TestLiquidationInvariantAssertions is CredibleTest, Test, TestnetProcedures {
  IMockL2Pool public pool;
  LiquidationInvariantAssertions public assertions;
  address public testUser;
  address public testLiquidator;
  address public testCollateralAsset;
  address public testDebtAsset;
  IERC20 public collateralUnderlying;
  IERC20 public debtUnderlying;
  string public constant ASSERTION_LABEL = 'LiquidationInvariantAssertions';
  IAaveOracle public aaveOracle;
  LiquidationDataProvider public liquidationDataProvider;

  function setUp() public {
    // Deploy mock protocol
    pool = new WorkingProtocol();

    // Set up users
    testUser = address(0x3333333333333333333333333333333333333333);
    testLiquidator = address(0x4444444444444444444444444444444444444444);
    testCollateralAsset = address(0x1111111111111111111111111111111111111111);
    testDebtAsset = address(0x2222222222222222222222222222222222222222);

    // Configure reserves as active
    WorkingProtocol(address(pool)).setReserveActive(testCollateralAsset, true);
    WorkingProtocol(address(pool)).setReserveActive(testDebtAsset, true);

    // Deploy assertions contract
    assertions = new LiquidationInvariantAssertions(pool);

    // Setup initial positions using L2Pool encoding
    vm.startPrank(testUser);

    // Supply collateral using L2Pool encoding
    // For mock protocol, we need to use manual encoding since asset mappings may differ
    uint16 assetId = _getAssetId(testCollateralAsset);
    uint16 referralCode = 0;
    bytes32 supplyArgs = bytes32(
      uint256(assetId) | (uint256(1000e6) << 16) | (uint256(referralCode) << 144)
    );
    pool.supply(supplyArgs);

    // Borrow using L2Pool encoding
    uint8 interestRateMode = 2; // VARIABLE
    bytes32 borrowArgs = bytes32(
      uint256(_getAssetId(testDebtAsset)) |
        (uint256(500e8) << 16) |
        (uint256(interestRateMode) << 144) |
        (uint256(referralCode) << 152)
    );
    pool.borrow(borrowArgs);
    vm.stopPrank();
  }

  function testAssertionHealthFactorThreshold() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LiquidationInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Make position unhealthy - this is the expected state for liquidation
    WorkingProtocol(address(pool)).setHealthFactor(testUser, 0.5e18);

    // Set liquidator as the caller
    vm.startPrank(testLiquidator);

    // Encode liquidation parameters for L2Pool
    // For L2Pool liquidationCall, we need two bytes32 parameters
    // args1: collateralAsset (20 bytes) + debtAsset (20 bytes) + user (20 bytes)
    // args2: debtToCover (16 bytes) + receiveAToken (1 byte) + unused (15 bytes)
    bytes32 args1 = bytes32(
      uint256(uint160(testCollateralAsset)) |
        (uint256(uint160(testDebtAsset)) << 160) |
        (uint256(uint160(testUser)) << 320)
    );
    bytes32 args2 = bytes32(
      uint256(100e8) | (uint256(0) << 128) // debtToCover // receiveAToken = false
    );

    // This should pass because the user's position is unhealthy and can be liquidated
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.liquidationCall.selector, args1, args2)
    );
    vm.stopPrank();
  }

  function testAssertionGracePeriod() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LiquidationInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set grace period to be in the past - this is the expected state for liquidation
    WorkingProtocol(address(pool)).setLiquidationGracePeriod(
      testCollateralAsset,
      uint40(block.timestamp)
    );

    // Fast forward time to be past the grace period
    vm.warp(block.timestamp + 1 days);

    // Make position unhealthy
    WorkingProtocol(address(pool)).setHealthFactor(testUser, 0.5e18);

    // Set liquidator as the caller
    vm.startPrank(testLiquidator);

    // Encode liquidation parameters for L2Pool
    // For L2Pool liquidationCall, we need two bytes32 parameters
    bytes32 args1 = bytes32(
      uint256(uint160(testCollateralAsset)) |
        (uint256(uint160(testDebtAsset)) << 160) |
        (uint256(uint160(testUser)) << 320)
    );
    bytes32 args2 = bytes32(
      uint256(100e8) | (uint256(0) << 128) // debtToCover // receiveAToken = false
    );

    // This should pass because the grace period has expired and liquidation is allowed
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.liquidationCall.selector, args1, args2)
    );
    vm.stopPrank();
  }

  /// @notice Helper function to get asset ID from asset address
  function _getAssetId(address assetAddress) internal pure returns (uint16) {
    // For mock assets, use hardcoded addresses
    if (assetAddress == address(0x1111111111111111111111111111111111111111)) {
      return 0;
    }
    if (assetAddress == address(0x2222222222222222222222222222222222222222)) {
      return 1;
    }
    // Default fallback
    return 0;
  }
}

contract MockAggregator {
  int256 private _price;

  constructor(int256 price) {
    _price = price;
  }

  function latestAnswer() external view returns (int256) {
    return _price;
  }
}
