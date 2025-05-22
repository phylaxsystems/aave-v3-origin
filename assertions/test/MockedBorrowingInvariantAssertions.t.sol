// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title MockedBorrowingInvariantAssertions Tests
 * @notice This test file uses a mocked version of the Aave V3 protocol to verify that
 *         our assertions correctly revert when the protocol violates our invariants.
 *         It ensures that our assertions actually catch and prevent invalid state
 *         changes.
 *
 *         For example, it verifies that the repay debt changes assertion reverts when
 *         a user repays assets but the protocol fails to decrease their debt,
 *         catching potential bugs in the protocol's implementation.
 *
 *         The mock pool is located in assertions/mocks/BrokenPool.sol
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {BorrowingPostConditionAssertions} from '../src/BorrowingInvariantAssertions.a.sol';
import {BrokenPool} from '../mocks/BrokenPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';

contract TestMockedBorrowingInvariantAssertions is CredibleTest, Test {
  BrokenPool public pool;
  BorrowingPostConditionAssertions public assertions;
  address public user;
  address public asset;
  IERC20 public underlying;
  string constant ASSERTION_LABEL = 'BorrowingInvariantAssertions';

  function setUp() public {
    // Deploy mock pool
    pool = new BrokenPool();

    // Set up user and asset
    user = address(0x1);
    asset = address(0x2);
    underlying = IERC20(asset);

    // Deploy assertions contract
    assertions = new BorrowingPostConditionAssertions(pool);

    // Set initial debt for user
    pool.setUserDebt(user, 500e6);

    // Configure mock to break repay debt changes
    pool.setBreakRepayDebt(true);
  }

  function test_assertionLiabilityDecreaseFailure() public {
    uint256 repayAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BorrowingPostConditionAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller
    vm.startPrank(user);

    // This should revert because the mock pool doesn't decrease debt
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(
        pool.repay.selector,
        asset,
        repayAmount,
        DataTypes.InterestRateMode.VARIABLE,
        user
      )
    );
    vm.stopPrank();
  }

  function test_assertionUnhealthyBorrowPreventionFailure() public {
    // Set up an unhealthy user (health factor < 1e18)
    pool.setUserDebt(user, 1000e6); // High debt to make user unhealthy

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(BorrowingPostConditionAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller
    vm.startPrank(user);

    // This should revert because the mock pool allows unhealthy users to borrow
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(
        pool.borrow.selector,
        asset,
        100e6,
        DataTypes.InterestRateMode.VARIABLE,
        0,
        user
      )
    );
    vm.stopPrank();
  }
}
