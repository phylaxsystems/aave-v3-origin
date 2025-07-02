// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {LiquidationInvariantAssertions} from '../src/showcase/LiquidationInvariantAssertions.a.sol';
import {IMockL2Pool} from '../src/interfaces/IMockL2Pool.sol';
import {BrokenPool} from '../mocks/BrokenPool.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {TestnetProcedures} from '../../tests/utils/TestnetProcedures.sol';
import {L2Encoder} from '../../src/contracts/helpers/L2Encoder.sol';
import {IPool} from '../../src/contracts/interfaces/IPool.sol';

contract TestMockedLiquidationInvariantAssertions is CredibleTest, Test, TestnetProcedures {
  IMockL2Pool public pool;
  LiquidationInvariantAssertions public assertions;
  L2Encoder public l2Encoder;
  address public user;
  address public liquidator;
  address public collateralAsset;
  address public debtAsset;
  IERC20 public collateralUnderlying;
  IERC20 public debtUnderlying;
  string public constant ASSERTION_LABEL = 'LiquidationInvariantAssertions';

  function setUp() public {
    // Deploy broken protocol
    pool = IMockL2Pool(address(new BrokenPool()));

    // Set up L2Encoder for creating compact parameters
    l2Encoder = new L2Encoder(IPool(address(pool)));

    // Set up users
    user = makeAddr('user');
    liquidator = makeAddr('liquidator');
    collateralAsset = address(0x1); // Match the asset ID mapping in BrokenPool
    debtAsset = address(0x2); // Match the asset ID mapping in BrokenPool

    // Configure reserves as active
    BrokenPool(address(pool)).setReserveActive(collateralAsset, true);
    BrokenPool(address(pool)).setReserveActive(debtAsset, true);

    // Deploy assertions contract
    assertions = new LiquidationInvariantAssertions();

    // Setup initial positions
    vm.startPrank(user);
    BrokenPool(address(pool)).supply(collateralAsset, 1000e6, user, 0);
    BrokenPool(address(pool)).borrow(debtAsset, 500e8, 2, 0, user);
    vm.stopPrank();
  }

  function testVerifyHealthFactor() public {
    // Set health factor
    BrokenPool(address(pool)).setUserHealthFactor(user, 1.5e18);

    // Verify health factor is set correctly
    (, , , , , uint256 healthFactor) = pool.getUserAccountData(user);
    require(healthFactor == 1.5e18, 'Health factor not set correctly');
  }

  function testAssertionHealthFactorThresholdFails() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LiquidationInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set health factor above 1 (healthy position)
    BrokenPool(address(pool)).setUserDebt(user, 100e8);
    BrokenPool(address(pool)).setUserHealthFactor(user, 1.5e18); // Set health factor to 1.5 (healthy)

    // Verify health factor is set correctly
    (, , , , , uint256 healthFactor) = pool.getUserAccountData(user);
    require(healthFactor == 1.5e18, 'Health factor not set correctly');

    // Set liquidator as the caller
    vm.startPrank(liquidator);

    // Create L2Pool compact parameters for liquidation
    (bytes32 args1, bytes32 args2) = l2Encoder.encodeLiquidationCall(
      collateralAsset,
      debtAsset,
      user,
      100e6,
      false
    );

    // This should fail because the user's position is healthy but we're trying to liquidate
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.liquidationCall.selector, args1, args2)
    );
    vm.stopPrank();
  }

  function testAssertionGracePeriodFails() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LiquidationInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set grace period to be in the future
    BrokenPool(address(pool)).setLiquidationGracePeriod(
      collateralAsset,
      uint40(block.timestamp + 1 days)
    );

    // Make position unhealthy
    BrokenPool(address(pool)).setUserDebt(user, 1000e8);

    // Set liquidator as the caller
    vm.startPrank(liquidator);

    // Create L2Pool compact parameters for liquidation
    (bytes32 args1, bytes32 args2) = l2Encoder.encodeLiquidationCall(
      collateralAsset,
      debtAsset,
      user,
      100e6,
      false
    );

    // This should fail because we're trying to liquidate during grace period
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.liquidationCall.selector, args1, args2)
    );
    vm.stopPrank();
  }

  function testAssertionCloseFactorConditionsFails() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LiquidationInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set up a position that violates close factor conditions
    BrokenPool(address(pool)).setUserDebt(user, 2000e8); // High debt
    BrokenPool(address(pool)).setUserDebt(liquidator, 1000e8); // High debt for liquidator

    // Set liquidator as the caller
    vm.startPrank(liquidator);

    // Create L2Pool compact parameters for liquidation
    (bytes32 args1, bytes32 args2) = l2Encoder.encodeLiquidationCall(
      collateralAsset,
      debtAsset,
      user,
      100e6,
      false
    );

    // This should fail because we're trying to liquidate more than close factor allows
    // and conditions for higher close factor are not met
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.liquidationCall.selector, args1, args2)
    );
    vm.stopPrank();
  }

  function testAssertionLiquidationAmountsFails() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LiquidationInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set up a position that violates liquidation amount requirements
    BrokenPool(address(pool)).setUserDebt(user, 100e8);
    BrokenPool(address(pool)).supply(collateralAsset, 50e6, user, 0);

    // Set liquidator as the caller
    vm.startPrank(liquidator);

    // Create L2Pool compact parameters for liquidation
    (bytes32 args1, bytes32 args2) = l2Encoder.encodeLiquidationCall(
      collateralAsset,
      debtAsset,
      user,
      100e6,
      false
    );

    // This should fail because we're trying to liquidate an amount that leaves
    // less than MIN_LEFTOVER_BASE on both sides
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.liquidationCall.selector, args1, args2)
    );
    vm.stopPrank();
  }

  function testAssertionDeficitCreationFails() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LiquidationInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set up a position that violates deficit creation requirements
    BrokenPool(address(pool)).setUserDebt(user, 100e8);
    BrokenPool(address(pool)).supply(collateralAsset, 50e6, user, 0);

    // Set liquidator as the caller
    vm.startPrank(liquidator);

    // Create L2Pool compact parameters for liquidation
    (bytes32 args1, bytes32 args2) = l2Encoder.encodeLiquidationCall(
      collateralAsset,
      debtAsset,
      user,
      100e6,
      false
    );

    // This should fail because we're trying to create a deficit while user still has collateral
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.liquidationCall.selector, args1, args2)
    );
    vm.stopPrank();
  }

  function testAssertionDeficitAccountingFails() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LiquidationInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set up a position that violates deficit accounting requirements
    BrokenPool(address(pool)).setUserDebt(user, 100e8);
    BrokenPool(address(pool)).setReserveDeficit(debtAsset, 0);

    // Set liquidator as the caller
    vm.startPrank(liquidator);

    // Create L2Pool compact parameters for liquidation
    (bytes32 args1, bytes32 args2) = l2Encoder.encodeLiquidationCall(
      collateralAsset,
      debtAsset,
      user,
      100e6,
      false
    );

    // This should fail because the deficit accounting doesn't match the debt burn
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.liquidationCall.selector, args1, args2)
    );
    vm.stopPrank();
  }

  function testAssertionDeficitAmountFails() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LiquidationInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set up a position that violates deficit amount requirements
    BrokenPool(address(pool)).setUserDebt(user, 100e8);
    BrokenPool(address(pool)).setReserveDeficit(debtAsset, 50e8); // Set deficit to half of debt

    // Set liquidator as the caller
    vm.startPrank(liquidator);

    // Create L2Pool compact parameters for liquidation
    (bytes32 args1, bytes32 args2) = l2Encoder.encodeLiquidationCall(
      collateralAsset,
      debtAsset,
      user,
      100e6,
      false
    );

    // This should fail because the deficit amount doesn't match the user's debt balance
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.liquidationCall.selector, args1, args2)
    );
    vm.stopPrank();
  }

  function testAssertionActiveReserveDeficitFails() public {
    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LiquidationInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set up a position that violates active reserve deficit requirements
    BrokenPool(address(pool)).setReserveActive(debtAsset, false); // Set debt asset as inactive
    BrokenPool(address(pool)).setUserDebt(user, 100e8);

    // Set liquidator as the caller
    vm.startPrank(liquidator);

    // Create L2Pool compact parameters for liquidation
    (bytes32 args1, bytes32 args2) = l2Encoder.encodeLiquidationCall(
      collateralAsset,
      debtAsset,
      user,
      100e6,
      false
    );

    // This should fail because we're trying to create deficit on an inactive reserve
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.liquidationCall.selector, args1, args2)
    );
    vm.stopPrank();
  }
}
