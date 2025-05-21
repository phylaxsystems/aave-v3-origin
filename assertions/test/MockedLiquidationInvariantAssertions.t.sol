// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {CredibleTest} from "credible-std/CredibleTest.sol";
import {LiquidationInvariantAssertions} from "../src/LiquidationInvariantAssertions.a.sol";
import {IMockPool} from "../src/IMockPool.sol";
import {BrokenPool} from "../mocks/BrokenPool.sol";
import {DataTypes} from "../../src/contracts/protocol/libraries/types/DataTypes.sol";
import {IERC20} from "../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {TestnetProcedures} from "../../tests/utils/TestnetProcedures.sol";

contract TestMockedLiquidationInvariantAssertions is CredibleTest, Test, TestnetProcedures {
    IMockPool public pool;
    LiquidationInvariantAssertions public assertions;
    address public user;
    address public liquidator;
    address public collateralAsset;
    address public debtAsset;
    IERC20 public collateralUnderlying;
    IERC20 public debtUnderlying;
    string constant ASSERTION_LABEL = "LiquidationInvariantAssertions";

    function setUp() public {
        // Deploy broken protocol
        pool = new BrokenPool();

        // Set up users
        user = makeAddr("user");
        liquidator = makeAddr("liquidator");
        collateralAsset = makeAddr("collateral");
        debtAsset = makeAddr("debt");

        // Configure reserves as active
        BrokenPool(address(pool)).setReserveActive(collateralAsset, true);
        BrokenPool(address(pool)).setReserveActive(debtAsset, true);

        // Deploy assertions contract
        assertions = new LiquidationInvariantAssertions(pool);

        // Setup initial positions
        vm.startPrank(user);
        BrokenPool(address(pool)).supply(collateralAsset, 1000e6, user, 0);
        BrokenPool(address(pool)).borrow(debtAsset, 500e8, 2, 0, user);
        vm.stopPrank();
    }

    function test_verifyHealthFactor() public {
        // Set health factor
        BrokenPool(address(pool)).setUserHealthFactor(user, 1.5e18);

        // Verify health factor is set correctly
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(user);
        require(healthFactor == 1.5e18, "Health factor not set correctly");
    }

    function test_assertionHealthFactorThreshold_Fails() public {
        // Associate the assertion with the protocol
        cl.addAssertion(
            ASSERTION_LABEL, address(pool), type(LiquidationInvariantAssertions).creationCode, abi.encode(pool)
        );

        // Set health factor above 1 (healthy position)
        BrokenPool(address(pool)).setUserDebt(user, 100e8);
        BrokenPool(address(pool)).setUserHealthFactor(user, 1.5e18); // Set health factor to 1.5 (healthy)

        // Verify health factor is set correctly
        (,,,,, uint256 healthFactor) = pool.getUserAccountData(user);
        require(healthFactor == 1.5e18, "Health factor not set correctly");

        // Set liquidator as the caller
        vm.startPrank(liquidator);

        // This should fail because the user's position is healthy but we're trying to liquidate
        vm.expectRevert("Assertions Reverted");
        cl.validate(
            ASSERTION_LABEL,
            address(pool),
            0,
            abi.encodeWithSelector(pool.liquidationCall.selector, collateralAsset, debtAsset, user, 100e8, false)
        );
        vm.stopPrank();
    }

    function test_assertionGracePeriod_Fails() public {
        // Associate the assertion with the protocol
        cl.addAssertion(
            ASSERTION_LABEL, address(pool), type(LiquidationInvariantAssertions).creationCode, abi.encode(pool)
        );

        // Set grace period to be in the future
        BrokenPool(address(pool)).setLiquidationGracePeriod(collateralAsset, uint40(block.timestamp + 1 days));

        // Make position unhealthy
        BrokenPool(address(pool)).setUserDebt(user, 1000e8);

        // Set liquidator as the caller
        vm.startPrank(liquidator);

        // This should fail because we're trying to liquidate during grace period
        vm.expectRevert("Assertions Reverted");
        cl.validate(
            ASSERTION_LABEL,
            address(pool),
            0,
            abi.encodeWithSelector(pool.liquidationCall.selector, collateralAsset, debtAsset, user, 100e8, false)
        );
        vm.stopPrank();
    }

    function test_assertionCloseFactorConditions_Fails() public {
        // Associate the assertion with the protocol
        cl.addAssertion(
            ASSERTION_LABEL, address(pool), type(LiquidationInvariantAssertions).creationCode, abi.encode(pool)
        );

        // Set up a position that violates close factor conditions
        BrokenPool(address(pool)).setUserDebt(user, 2000e8); // High debt
        BrokenPool(address(pool)).setUserDebt(liquidator, 1000e8); // High debt for liquidator

        // Set liquidator as the caller
        vm.startPrank(liquidator);

        // This should fail because we're trying to liquidate more than close factor allows
        // and conditions for higher close factor are not met
        vm.expectRevert("Assertions Reverted");
        cl.validate(
            ASSERTION_LABEL,
            address(pool),
            0,
            abi.encodeWithSelector(pool.liquidationCall.selector, collateralAsset, debtAsset, user, 1500e8, false)
        );
        vm.stopPrank();
    }

    function test_assertionLiquidationAmounts_Fails() public {
        // Associate the assertion with the protocol
        cl.addAssertion(
            ASSERTION_LABEL, address(pool), type(LiquidationInvariantAssertions).creationCode, abi.encode(pool)
        );

        // Set up a position that violates liquidation amount requirements
        BrokenPool(address(pool)).setUserDebt(user, 100e8);
        BrokenPool(address(pool)).supply(collateralAsset, 50e6, user, 0);

        // Set liquidator as the caller
        vm.startPrank(liquidator);

        // This should fail because we're trying to liquidate an amount that leaves
        // less than MIN_LEFTOVER_BASE on both sides
        vm.expectRevert("Assertions Reverted");
        cl.validate(
            ASSERTION_LABEL,
            address(pool),
            0,
            abi.encodeWithSelector(pool.liquidationCall.selector, collateralAsset, debtAsset, user, 90e8, false)
        );
        vm.stopPrank();
    }

    function test_assertionDeficitCreation_Fails() public {
        // Associate the assertion with the protocol
        cl.addAssertion(
            ASSERTION_LABEL, address(pool), type(LiquidationInvariantAssertions).creationCode, abi.encode(pool)
        );

        // Set up a position that violates deficit creation requirements
        BrokenPool(address(pool)).setUserDebt(user, 100e8);
        BrokenPool(address(pool)).supply(collateralAsset, 10e6, user, 0);

        // Set liquidator as the caller
        vm.startPrank(liquidator);

        // This should fail because we're trying to create a deficit while there's still collateral
        vm.expectRevert("Assertions Reverted");
        cl.validate(
            ASSERTION_LABEL,
            address(pool),
            0,
            abi.encodeWithSelector(pool.liquidationCall.selector, collateralAsset, debtAsset, user, 100e8, false)
        );
        vm.stopPrank();
    }

    function test_assertionDeficitAccounting_Fails() public {
        // Associate the assertion with the protocol
        cl.addAssertion(
            ASSERTION_LABEL, address(pool), type(LiquidationInvariantAssertions).creationCode, abi.encode(pool)
        );

        // Set up a position that violates deficit accounting
        BrokenPool(address(pool)).setUserDebt(user, 100e8);
        BrokenPool(address(pool)).setReserveDeficit(debtAsset, 10e8);

        // Set liquidator as the caller
        vm.startPrank(liquidator);

        // This should fail because the deficit accounting doesn't match the debt burn
        vm.expectRevert("Assertions Reverted");
        cl.validate(
            ASSERTION_LABEL,
            address(pool),
            0,
            abi.encodeWithSelector(pool.liquidationCall.selector, collateralAsset, debtAsset, user, 100e8, false)
        );
        vm.stopPrank();
    }

    function test_assertionDeficitAmount_Fails() public {
        // Associate the assertion with the protocol
        cl.addAssertion(
            ASSERTION_LABEL, address(pool), type(LiquidationInvariantAssertions).creationCode, abi.encode(pool)
        );

        // Set up a position that violates deficit amount requirements
        BrokenPool(address(pool)).setUserDebt(user, 100e8);
        BrokenPool(address(pool)).setReserveDeficit(debtAsset, 50e8);

        // Set liquidator as the caller
        vm.startPrank(liquidator);

        // This should fail because we're trying to create a deficit larger than the user's debt
        vm.expectRevert("Assertions Reverted");
        cl.validate(
            ASSERTION_LABEL,
            address(pool),
            0,
            abi.encodeWithSelector(pool.liquidationCall.selector, collateralAsset, debtAsset, user, 100e8, false)
        );
        vm.stopPrank();
    }

    function test_assertionActiveReserveDeficit_Fails() public {
        // Associate the assertion with the protocol
        cl.addAssertion(
            ASSERTION_LABEL, address(pool), type(LiquidationInvariantAssertions).creationCode, abi.encode(pool)
        );

        // Set up reserves as inactive
        BrokenPool(address(pool)).setReserveActive(collateralAsset, false);
        BrokenPool(address(pool)).setReserveActive(debtAsset, false);

        // Set liquidator as the caller
        vm.startPrank(liquidator);

        // This should fail because we're trying to liquidate on inactive reserves
        vm.expectRevert("Assertions Reverted");
        cl.validate(
            ASSERTION_LABEL,
            address(pool),
            0,
            abi.encodeWithSelector(pool.liquidationCall.selector, collateralAsset, debtAsset, user, 100e8, false)
        );
        vm.stopPrank();
    }
}
