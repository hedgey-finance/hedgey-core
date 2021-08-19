pragma solidity ^0.6.12;


import libraries.sol

import hedgeyCallsV2.sol



pragma solidity ^0.6.12;

contract HedgeyCallsFactoryV2 {
    
    mapping(address => mapping(address => address)) public pairs;
    address[] public totalContracts;
    address payable public collector;
    bool public collectorSet; //this is set to false until we define the staking contract as the collector 
    uint public fee;
    
    

    constructor (address payable _collector, uint _fee, bool _collectorSet) public {
        collector = _collector;
        fee = _fee;
        collectorSet = _collectorSet;
       
    }
    
    function changeFee(uint _newFee) public {
        require(msg.sender == collector, "youre not the collector");
        fee = _newFee;
    }

    function changeCollector(address payable _collector, bool _set) public returns (bool) {
        require(msg.sender == collector, "youre not the collector");
        collector = _collector;
        collectorSet = _set;
        return _set;
    }

    
    function getPair(address asset, address pymtCurrency) public view returns (address pair) {
        pair = pairs[asset][pymtCurrency];
    }

    function createContract(address asset, address pymtCurrency) public {
        require(asset != pymtCurrency, "same currencies");
        require(pairs[asset][pymtCurrency] == address(0), "contract exists");
        HedgeyCallsV2 callContract = new HedgeyCallsV2(asset, pymtCurrency, collector, fee, collectorSet);
        pairs[asset][pymtCurrency] = address(callContract);
        totalContracts.push(address(callContract));
        if (collectorSet) {
            IHedgeyStaking(collector).addWhitelist(address(callContract));
        }
        emit NewPairCreated(asset, pymtCurrency, address(callContract));
    }

    event NewPairCreated(address _asset, address _pymtCurrency, address _pair);
}

