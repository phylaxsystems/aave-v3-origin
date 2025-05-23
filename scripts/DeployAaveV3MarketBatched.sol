// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {DeployAaveV3MarketBatchedBase} from './misc/DeployAaveV3MarketBatchedBase.sol';

import {PhylaxTestnetMarketInput} from '../src/deployments/inputs/PhylaxTestnetMarketInput.sol';

contract PhylaxTestnetDeploy is DeployAaveV3MarketBatchedBase, PhylaxTestnetMarketInput {}
