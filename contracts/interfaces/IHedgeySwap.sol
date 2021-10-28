
pragma solidity ^0.6.12;

//interface for swapping using multi-legged flash loans

interface IHedgeySwap {
    function hedgeyPutSwap(address originalOwner, uint _c, uint _totalPurchase, address[] memory path) external;
}
