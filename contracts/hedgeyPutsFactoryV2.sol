
pragma solidity ^0.6.12;


import libraries.sol

import hedgeyPutsV2.sol



pragma solidity ^0.6.12;




contract HedgeyPutsFactoryV2 {
    
    mapping(address => mapping(address => address)) public pairs;
    address[] public totalContracts;
    address payable public collector;
    bool public collectorSet; //set to false until we have set and defined the staking contract
    uint public fee;

    constructor (address payable _collector, uint _fee, bool _collectorSet) public {
        collector = _collector;
        fee = _fee;
        collectorSet = _collectorSet;
    }
    
    function changeFee(uint _newFee) public {
        require(msg.sender == collector, "only the collector");
        fee = _newFee;
    }

    function changeCollector(address payable _collector, bool _set) public returns (bool) {
        require(msg.sender == collector, "only the collector");
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
        HedgeyPutsV2 putContract = new HedgeyPutsV2(asset, pymtCurrency, collector, fee, collectorSet);
        pairs[asset][pymtCurrency] = address(putContract);
        totalContracts.push(address(putContract));
        if (collectorSet) {
            IHedgeyStaking(collector).addWhitelist(address(putContract));
        }
        emit NewPairCreated(asset, pymtCurrency, address(putContract));
    }

    event NewPairCreated(address _asset, address _pymtCurrency, address _pair);
}
