//interface for HedgeyCalls and HedgeyPuts Pair contracts
//both calls and puts have same functions and so same interface can be used to interact with either after instantiation
//additional modifiers may be required for customized function usage


pragma solidity ^0.6.12;

interface IHedgeyPair {


    //public variables
    function asset() external view returns (address);
    function pymtCurrency() external view returns (address);
    function uniPair() external view returns (address);
    function weth() external view returns (address);
    function fee() external view returns (uint);
    function uniFactory() external view returns (address);
    function cashCloseOn() external view returns (bool);

    function updateAMM() external;

    //core functions
    function newBid(uint _assetAmount, uint _strike, uint _price, uint _expiry) payable external;
    function cancelNewBid(uint _i) external;
    function sellOpenOptionToNewBid(uint _i, uint _j, uint _price) payable external;
    function sellNewOption(uint _i, uint _assetAmount, uint _strike, uint _price, uint _expiry) payable external;
    function changeNewOption(uint _i, uint _assetAmount, uint _strike, uint _price, uint _expiry) payable external;
    function newAsk(uint _assetAmount, uint _strike, uint _price, uint _expiry) payable external;
    function cancelNewAsk(uint _i) external;
    function buyNewOption(uint _i, uint _assetAmount, uint _strike, uint _price, uint _expiry) payable external;
    function buyOptionFromAsk(uint _i, uint _j, uint _price) payable external;
    function setPrice(uint _i, uint _price, bool _tradeable) external;
    function buyOpenOption(uint _i, uint _assetAmount, uint _strike, uint _price, uint _expiry) payable external;
    function exercise(uint _i) payable external;
    function cashClose(uint _i, bool cashBack) payable external;
    function returnExpired(uint _i) external;
    function rollExpired(uint _i, uint _assetAmount, uint _newStrike, uint _price, uint _newExpiry) payable external;


    //events
    event NewBid(uint _i, uint _assetAmt, uint _strike, uint _price, uint _expiry);
    event NewAsk(uint _i, uint _assetAmt, uint _strike, uint _price, uint _expiry);
    event NewOptionSold(uint _i);
    event NewOptionBought(uint _i);
    event OpenOptionSold(uint _i, uint _j, address _long, uint _price);
    event OpenShortRePurchased(uint _i, uint _j, address _short, uint _price);
    event OpenOptionPurchased(uint _i);
    event OptionChanged(uint _i, uint _assetAmt, uint _strike, uint _price, uint _expiry);
    event PriceSet(uint _i, uint _price, bool _tradeable);
    event OptionExercised(uint _i, bool cashClosed);
    event OptionRolled(uint _i, uint _j, uint _assetAmt, uint _strike, uint _price, uint _expiry);
    event OptionReturned(uint _i);
    event OptionCancelled(uint _i);
    event AMMUpdate(bool _cashCloseOn);

}
