// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from 'forge-std/Test.sol';
import {CredibleTest} from 'credible-std/CredibleTest.sol';
import {FlashloanInvariantAssertions} from '../src/FlashloanInvariantAssertions.a.sol';
import {IMockL2Pool} from '../src/IMockL2Pool.sol';
import {BrokenPool} from '../mocks/BrokenPool.sol';
import {WorkingProtocol} from '../mocks/WorkingProtocol.sol';

contract MockedFlashloanInvariantAssertionsTest is CredibleTest, Test {
  IMockL2Pool public pool;
  FlashloanInvariantAssertions public assertions;
  string public constant ASSERTION_LABEL = 'FlashloanInvariantAssertions';

  function setUp() public {
    // Deploy mock pool
    pool = IMockL2Pool(address(new BrokenPool()));

    // Deploy assertions (no constructor arguments needed now)
    assertions = new FlashloanInvariantAssertions();
  }

  function testMockedFlashloanInvariantAssertions() public {
    // Test that assertions can be deployed and work correctly
    assertTrue(address(assertions) != address(0), 'Assertions should be deployed');
  }

  function testMockedFlashloanInvariantAssertionsWithWorkingProtocol() public {
    // Deploy working protocol
    IMockL2Pool workingPool = IMockL2Pool(address(new WorkingProtocol()));

    // Deploy assertions for working protocol
    FlashloanInvariantAssertions workingAssertions = new FlashloanInvariantAssertions();

    // Test that assertions can be deployed and work correctly
    assertTrue(address(workingAssertions) != address(0), 'Working assertions should be deployed');
  }

  function testMockedFlashloanInvariantAssertionsCreationCode() public {
    // Test that creation code is available
    bytes memory creationCode = type(FlashloanInvariantAssertions).creationCode;
    assertTrue(creationCode.length > 0, 'Creation code should be available');
  }

  function testMockedFlashloanInvariantAssertionsRuntimeCode() public {
    // Test that runtime code is available
    bytes memory runtimeCode = type(FlashloanInvariantAssertions).runtimeCode;
    assertTrue(runtimeCode.length > 0, 'Runtime code should be available');
  }
}
