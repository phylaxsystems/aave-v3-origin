// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/**
 * @title MockedLendingInvariantAssertions Tests
 * @notice This test file uses a mocked version of the Aave V3 protocol to verify that
 *         our assertions correctly revert when the protocol violates our invariants.
 *         It ensures that our assertions actually catch and prevent invalid state
 *         changes.
 *
 *         For example, it verifies that the deposit balance changes assertion reverts when
 *         a user deposits assets but the protocol fails to update balances correctly,
 *         catching potential bugs in the protocol's implementation.
 *
 *         The mock pool is located in assertions/mocks/BrokenPool.sol
 */
import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {LendingPostConditionAssertions} from '../src/LendingInvariantAssertions.a.sol';
import {BrokenPool} from '../mocks/BrokenPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {ReserveConfiguration} from '../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';

contract TestMockedLendingInvariantAssertions is CredibleTest, Test {
  BrokenPool public pool;
  LendingPostConditionAssertions public assertions;
  address public user;
  address public asset;
  IERC20 public underlying;
  string constant ASSERTION_LABEL = 'LendingInvariantAssertions';

  function setUp() public {
    // Deploy mock pool
    pool = new BrokenPool();

    // Set up user and asset
    user = address(0x1);
    asset = address(0x2);
    underlying = IERC20(asset);

    // Deploy assertions contract
    assertions = new LendingPostConditionAssertions(pool);

    // Set up reserve states according to the invariant
    // Reserve must be active, not frozen, and not paused
    pool.setReserveActive(asset, true);
    pool.setReserveFrozen(asset, false);
    pool.setReservePaused(asset, false);

    // Verify reserve state is set correctly
    DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);
    bool isActive = ReserveConfiguration.getActive(reserveData.configuration);
    bool isFrozen = ReserveConfiguration.getFrozen(reserveData.configuration);
    bool isPaused = ReserveConfiguration.getPaused(reserveData.configuration);

    require(isActive, 'Reserve should be active after setup');
    require(!isFrozen, 'Reserve should not be frozen after setup');
    require(!isPaused, 'Reserve should not be paused after setup');

    // Set up mock pool to break deposit balance changes
    pool.setBreakDepositBalance(true);
  }

  function test_assertionDepositBalanceChangesFailure() public {
    uint256 depositAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LendingPostConditionAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller
    vm.startPrank(user);

    // This should revert because the mock pool doesn't update balances
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, asset, depositAmount, user, 0)
    );
    vm.stopPrank();
  }

  function test_assertionWithdrawBalanceChangesFailure() public {
    uint256 depositAmount = 100e6;
    uint256 withdrawAmount = 50e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LendingPostConditionAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller
    vm.startPrank(user);

    // First deposit some tokens
    pool.supply(asset, depositAmount, user, 0);

    // Set up mock pool to break withdraw balance changes
    pool.setBreakWithdrawBalance(true);

    // This should revert because the mock pool doesn't update balances
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.withdraw.selector, asset, withdrawAmount, user)
    );
    vm.stopPrank();
  }
}
