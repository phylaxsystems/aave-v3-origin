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
import {LendingInvariantAssertions} from '../src/LendingInvariantAssertions.a.sol';
import {IMockL2Pool} from '../src/IMockL2Pool.sol';
import {BrokenPool} from '../mocks/BrokenPool.sol';
import {DataTypes} from '../../src/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20} from '../../src/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {ReserveConfiguration} from '../../src/contracts/protocol/libraries/configuration/ReserveConfiguration.sol';
import {L2Encoder} from '../../src/contracts/helpers/L2Encoder.sol';
import {IPool} from '../../src/contracts/interfaces/IPool.sol';

contract TestMockedLendingInvariantAssertions is CredibleTest, Test {
  IMockL2Pool public pool;
  LendingInvariantAssertions public assertions;
  L2Encoder public l2Encoder;
  address public user;
  address public asset;
  IERC20 public underlying;
  string public constant ASSERTION_LABEL = 'LendingInvariantAssertions';

  function setUp() public {
    // Deploy mock pool
    pool = IMockL2Pool(address(new BrokenPool()));

    // Set up user and asset
    user = address(0x1);
    asset = address(0x2);
    underlying = IERC20(asset);

    // Set up L2Encoder for creating compact parameters
    l2Encoder = new L2Encoder(IPool(address(pool)));

    // Deploy assertions contract
    assertions = new LendingInvariantAssertions();

    // Set up reserve states according to the invariant
    // Reserve must be active, not frozen, and not paused
    BrokenPool(address(pool)).setReserveActive(asset, true);
    BrokenPool(address(pool)).setReserveFrozen(asset, false);
    BrokenPool(address(pool)).setReservePaused(asset, false);

    // Verify reserve state is set correctly
    DataTypes.ReserveDataLegacy memory reserveData = pool.getReserveData(asset);
    bool isActive = ReserveConfiguration.getActive(reserveData.configuration);
    bool isFrozen = ReserveConfiguration.getFrozen(reserveData.configuration);
    bool isPaused = ReserveConfiguration.getPaused(reserveData.configuration);

    require(isActive, 'Reserve should be active after setup');
    require(!isFrozen, 'Reserve should not be frozen after setup');
    require(!isPaused, 'Reserve should not be paused after setup');

    // Set up mock pool to break deposit balance changes
    BrokenPool(address(pool)).setBreakDepositBalance(true);
  }

  function testAssertionDepositBalanceChangesFailure() public {
    uint256 depositAmount = 100e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LendingInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, depositAmount, 0);

    // This should revert because the mock pool doesn't update balances
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.supply.selector, supplyArgs)
    );
    vm.stopPrank();
  }

  function testAssertionWithdrawBalanceChangesFailure() public {
    uint256 depositAmount = 100e6;
    uint256 withdrawAmount = 50e6;

    // Associate the assertion with the protocol
    cl.addAssertion(
      ASSERTION_LABEL,
      address(pool),
      type(LendingInvariantAssertions).creationCode,
      abi.encode(pool)
    );

    // Set user as the caller
    vm.startPrank(user);

    // Create L2Pool compact parameters for supply
    bytes32 supplyArgs = l2Encoder.encodeSupplyParams(asset, depositAmount, 0);

    // First deposit some tokens - cast to IMockL2Pool to avoid ambiguity
    IMockL2Pool(address(pool)).supply(supplyArgs);

    // Set up mock pool to break withdraw balance changes
    BrokenPool(address(pool)).setBreakWithdrawBalance(true);

    // Create L2Pool compact parameters for withdraw
    bytes32 withdrawArgs = l2Encoder.encodeWithdrawParams(asset, withdrawAmount);

    // This should revert because the mock pool doesn't update balances
    vm.expectRevert('Assertions Reverted');
    cl.validate(
      ASSERTION_LABEL,
      address(pool),
      0,
      abi.encodeWithSelector(pool.withdraw.selector, withdrawArgs)
    );
    vm.stopPrank();
  }
}
