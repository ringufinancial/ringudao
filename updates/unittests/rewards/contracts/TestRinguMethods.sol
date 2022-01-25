// SPDX-License-Identifier: MIT

pragma solidity >=0.7.0 <0.9.0;

import '../lib/SafeMath.sol';
import '../lib/Strings.sol';
import "hardhat/console.sol";

contract TestRinguMethods {
    using SafeMath for uint256;
    
    address public deadWallet = 0x000000000000000000000000000000000000dEaD;
    
    string private testNodeName = "testNode";
    uint256 rewardPerNode = 50006249999998560;
    
    using IterableMapping for IterableMapping.Map;

    struct NodeEntity {
        string name;
        uint256 creationTime;
        uint256 lastClaimTime;
        uint256 rewardAvailable;
    }

    IterableMapping.Map private nodeOwners;
    mapping(address => NodeEntity[]) private _nodesOfUser;
    
    constructor(string memory _name) {

        _nodesOfUser[deadWallet].push(
            NodeEntity({
                name: testNodeName,
                creationTime: block.timestamp - 1 days,
                lastClaimTime: block.timestamp - 1 days,
                rewardAvailable: rewardPerNode
            })
        );
        
    }

    function getRewardForOneNodeWallet() public view returns (string memory) {
        uint256 result = _getRewardsAvailable(_nodesOfUser[deadWallet][0]);
        return Strings.toString(result);
    }
    
    function _getRewardsAvailable(NodeEntity memory node) public view returns (uint256) {
        uint256 newClaimTime = block.timestamp;
        uint256 secondsSinceLastClaim = newClaimTime.sub(node.lastClaimTime);
        uint256 minutesSinceLastClaim = secondsSinceLastClaim.div(60);
        uint256 minutesInDay = 1440;
        uint256 rewardPerMinute = rewardPerNode.div(minutesInDay);
        uint256 totalRewards = minutesSinceLastClaim.mul(rewardPerMinute);
        console.log("rewardPerMinute: %d", rewardPerMinute);
        console.log("totalRewards: %d", totalRewards);
        return totalRewards;
    }
}