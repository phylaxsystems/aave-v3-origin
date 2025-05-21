// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {CredibleTest} from "credible-std/CredibleTest.sol";
import {FlashloanPostConditionAssertions} from "../src/FlashloanInvariantAssertions.a.sol";
import {BrokenPool} from "../mocks/BrokenPool.sol";
import {DataTypes} from "../../src/contracts/protocol/libraries/types/DataTypes.sol";
import {IERC20} from "../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol";
import {ReserveConfiguration} from "../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {TestnetERC20} from "../../src/contracts/mocks/testnet-helpers/TestnetERC20.sol";

contract TestMockedFlashloanInvariantAssertions is CredibleTest, Test {
    BrokenPool public pool;
    FlashloanPostConditionAssertions public assertions;
    address public user;
    TestnetERC20 public asset;
    IERC20 public underlying;
    string constant ASSERTION_LABEL = "FlashloanInvariantAssertions";

    function setUp() public {
        // Deploy mock pool
        pool = new BrokenPool();

        // Set up user and asset
        user = address(0x1);
        asset = new TestnetERC20("Test Token", "TEST", 18, address(this));
        underlying = IERC20(address(asset));

        // Deploy assertions contract
        assertions = new FlashloanPostConditionAssertions(pool);

        // Set up reserve states according to the invariant
        pool.setReserveActive(address(asset), true);
        pool.setReserveFrozen(address(asset), false);
        pool.setReservePaused(address(asset), false);

        // Set up mock pool to break flashloan repayment
        pool.setBreakFlashloanRepayment(true);

        // Mint tokens to the pool
        asset.mint(address(pool), 1000e18);
    }

    function test_assertionFlashloanRepaymentFailure() public {
        uint256 amount = 100e18;
        bytes memory emptyParams;

        // Associate the assertion with the protocol
        cl.addAssertion(
            ASSERTION_LABEL, address(pool), type(FlashloanPostConditionAssertions).creationCode, abi.encode(pool)
        );

        // Set user as the caller
        vm.startPrank(user);

        // This should revert because the mock pool doesn't require repayment
        vm.expectRevert("Assertions Reverted");
        cl.validate(
            ASSERTION_LABEL,
            address(pool),
            0,
            abi.encodeWithSelector(pool.flashLoanSimple.selector, user, address(asset), amount, emptyParams, 0)
        );
        vm.stopPrank();
    }
}
