// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC2981} from "@openzeppelin/contracts/interfaces/IERC2981.sol";
import {IBrushToken} from "./interfaces/IBrushToken.sol";

import {BokkyPooBahsRedBlackTreeLibrary} from "./BokkyPooBahsRedBlackTreeLibrary.sol";

contract OrderBook is ERC1155Holder, UUPSUpgradeable, OwnableUpgradeable {
  using BokkyPooBahsRedBlackTreeLibrary for BokkyPooBahsRedBlackTreeLibrary.Tree;

  event OrderPlaced(bool isBuy, address from, uint tokenId, uint quantity, uint price);
  // TODO: Bulk this event
  event OrderMatched(address maker, address taker, uint tokenId, uint quantity, uint price);
  event OrderCancelled(uint id); // bool isBuy, address maker, uint tokenId, uint quantity, uint price); // Remaining?
  event AddedToBook(bool isBuy, OrderBookEntry orderBookEntry, uint price);
  event RemovedFromBook(uint id);
  event PartialRemovedFromBook(uint id, uint quantityRemoved);
  event ClaimedTokens(address owner);
  event ClaimedNFTs(address owner, uint tokenId);
  event SetTokenIdInfos(uint[] tokenIds, TokenIdInfo[] _tokenIdInfos);

  error NotERC1155();
  error NoQuantity();
  error OrderNotFound();
  error PriceNotMultipleOfTick(uint tick);
  error TokenDoesntExist(uint tokenId);
  error PriceZero();
  error LengthMismatch();
  error QuantityRemainingTooLow();

  enum OrderSide {
    Buy,
    Sell
  }

  struct OrderBookEntry {
    address owner;
    uint32 quantity;
    uint64 id;
  }

  mapping(uint tokenId => BokkyPooBahsRedBlackTreeLibrary.Tree) public asks;
  mapping(uint tokenId => BokkyPooBahsRedBlackTreeLibrary.Tree) public bids;

  IERC1155 public nft;
  IBrushToken public token;

  address public devAddr;
  uint8 public devFee; // Base 10000, max 2.55%
  uint8 public burntFee;
  uint16 public maxOrdersPerPrice;
  bool public supportsERC2981;
  uint64 public nextOrderEntryId;

  struct TokenIdInfo {
    uint128 tick;
    uint128 minQuantity;
  }

  mapping(uint tokenId => TokenIdInfo tokenIdInfo) public tokenIdInfos;

  mapping(uint tokenId => mapping(uint price => OrderBookEntry[])) public askValues;
  mapping(uint tokenId => mapping(uint price => OrderBookEntry[])) public bidValues;

  // Check has much gas changes if actually just transferring the tokens.
  mapping(address user => uint amount) private brushClaimable;
  mapping(address user => mapping(uint tokenId => uint amount)) private tokenIdsClaimable;

  /// @custom:oz-upgrades-unsafe-allow constructor
  constructor() {
    _disableInitializers();
  }

  function initialize(address _nft, address _token, address _devAddr) external initializer {
    __UUPSUpgradeable_init();
    __Ownable_init(msg.sender);

    nft = IERC1155(_nft);
    if (!nft.supportsInterface(type(IERC1155).interfaceId)) {
      revert NotERC1155();
    }
    token = IBrushToken(_token);
    supportsERC2981 = IERC1155(_nft).supportsInterface(type(IERC2981).interfaceId);

    devFee = 30; // 30 = 0.3% fee,
    devAddr = _devAddr;
    burntFee = 30; // 30 = 0.3% fee,
    maxOrdersPerPrice = 100;

    nextOrderEntryId = 1;
  }

  function limitOrder(OrderSide _side, uint _tokenId, uint64 _price, uint32 _quantity) external {
    if (_quantity == 0) {
      revert NoQuantity();
    }

    if (_price == 0) {
      revert PriceZero();
    }

    TokenIdInfo memory tokenIdInfo = tokenIdInfos[_tokenId];
    uint tick = tokenIdInfo.tick;
    if (_price % tick != 0) {
      revert PriceNotMultipleOfTick(tick);
    }

    if (tokenIdInfos[_tokenId].tick == 0) {
      revert TokenDoesntExist(_tokenId);
    }

    bool isBuy = _side == OrderSide.Buy;
    (uint32 quantityRemaining, uint cost) = takeFromOrderBook(isBuy, _tokenId, _price, _quantity);

    if (quantityRemaining != 0 && quantityRemaining < tokenIdInfo.minQuantity) {
      revert QuantityRemainingTooLow();
    }

    // Add the rest to the order book
    if (quantityRemaining > 0) {
      addToBook(isBuy, _tokenId, _price, quantityRemaining);
    }

    if (isBuy) {
      // User transfers all tokens to us first
      token.transferFrom(msg.sender, address(this), cost + uint(_price) * quantityRemaining);
      _sendFees(_tokenId, cost);
      // Transfer the NFTs straight to the user
      if (cost > 0) {
        nft.safeTransferFrom(address(this), msg.sender, _tokenId, _quantity - quantityRemaining, "");
      }
    } else {
      // Selling, transfer all NFTs to us
      nft.safeTransferFrom(msg.sender, address(this), _tokenId, _quantity, "");

      // Transfer tokens to the seller if any have sold
      if (cost > 0) {
        uint fees = _sendFees(_tokenId, cost);
        _safeTransferFromUs(msg.sender, cost + uint(_price) * quantityRemaining - fees);
      }
    }

    emit OrderPlaced(isBuy, msg.sender, _tokenId, _price, _quantity);
  }

  //  function batchLimitOrder

  // TODO, require minimums so that we can limit the amount of orders in the book?
  function buyTakeFromOrderBook(
    uint _tokenId,
    uint80 _price,
    uint32 _quantity
  ) private returns (uint32 quantityRemaining, uint cost) {
    quantityRemaining = _quantity;
    //    uint quantityBought = 0;
    while (quantityRemaining > 0) {
      uint64 lowestAsk = getLowestAsk(_tokenId);
      if (lowestAsk == 0 || lowestAsk > _price) {
        // No more orders left
        break;
      }

      // Loop through all at this order
      uint numFullyConsumed = 0;

      for (uint i = asks[_tokenId].getNode(lowestAsk).tombstoneOffset; i < askValues[_tokenId][lowestAsk].length; ++i) {
        uint32 quantityL3 = askValues[_tokenId][lowestAsk][i].quantity;
        uint quantityNFTClaimable = 0;
        if (quantityRemaining >= quantityL3) {
          // Consume this whole order
          quantityRemaining -= quantityL3;
          ++numFullyConsumed;
          quantityNFTClaimable = quantityL3;
          cost += quantityNFTClaimable * lowestAsk;
        } else {
          // Eat into the order
          askValues[_tokenId][lowestAsk][i].quantity -= quantityRemaining;
          quantityNFTClaimable = quantityRemaining;
          cost += quantityNFTClaimable * lowestAsk;
          quantityRemaining = 0;
        }
        emit OrderMatched(
          askValues[_tokenId][lowestAsk][i].owner,
          msg.sender,
          _tokenId,
          quantityNFTClaimable,
          lowestAsk
        );
        tokenIdsClaimable[askValues[_tokenId][lowestAsk][i].owner][_tokenId] += quantityNFTClaimable;
      }
      // We consumed all orders at this price, so remove all
      if (
        numFullyConsumed == askValues[_tokenId][lowestAsk].length - asks[_tokenId].getNode(lowestAsk).tombstoneOffset
      ) {
        asks[_tokenId].remove(lowestAsk);
        delete askValues[_tokenId][lowestAsk];
      } else {
        // Increase tombstone offset of this price for gas efficiency
        asks[_tokenId].edit(lowestAsk, uint32(numFullyConsumed));
      }
    }
  }

  function sellTakeFromOrderBook(
    uint _tokenId,
    uint _price,
    uint32 _quantity
  ) private returns (uint32 quantityRemaining, uint cost) {
    quantityRemaining = _quantity;

    uint royaltyFee;
    if (supportsERC2981) {
      address recipient;
      (recipient, royaltyFee) = IERC2981(address(nft)).royaltyInfo(_tokenId, 10000);
    }

    // Selling
    while (quantityRemaining > 0) {
      uint64 highestBid = getHighestBid(_tokenId);
      if (highestBid == 0 || highestBid < _price) {
        // No more orders left
        break;
      }

      // Loop through all at this order
      uint numFullyConsumed = 0;
      for (
        uint i = bids[_tokenId].getNode(highestBid).tombstoneOffset;
        i < bidValues[_tokenId][highestBid].length;
        ++i
      ) {
        uint32 quantityL3 = bidValues[_tokenId][highestBid][i].quantity;
        uint amountBrushClaimable = 0;
        if (quantityRemaining >= quantityL3) {
          // Consume this whole order
          quantityRemaining -= quantityL3;
          ++numFullyConsumed;

          uint _amountBrushClaimable = quantityL3 * highestBid;
          amountBrushClaimable = _amountBrushClaimable;
          // Subtract the fees
          amountBrushClaimable -= (_amountBrushClaimable * devFee) / 10000;
          amountBrushClaimable -= (_amountBrushClaimable * royaltyFee) / 10000;
          amountBrushClaimable -= (_amountBrushClaimable * burntFee) / 10000;
          cost += amountBrushClaimable;
          emit OrderMatched(bidValues[_tokenId][highestBid][i].owner, msg.sender, _tokenId, quantityL3, highestBid);
        } else {
          // Eat into the order
          bidValues[_tokenId][highestBid][i].quantity -= quantityRemaining;
          uint _amountBrushClaimable = quantityRemaining * highestBid;
          amountBrushClaimable = _amountBrushClaimable;
          // Subtract the fees
          amountBrushClaimable -= (_amountBrushClaimable * devFee) / 10000;
          amountBrushClaimable -= (_amountBrushClaimable * royaltyFee) / 10000;
          amountBrushClaimable -= (_amountBrushClaimable * burntFee) / 10000;
          cost += amountBrushClaimable;
          emit OrderMatched(
            bidValues[_tokenId][highestBid][i].owner,
            msg.sender,
            _tokenId,
            quantityRemaining,
            highestBid
          );
          quantityRemaining = 0;
        }
        brushClaimable[bidValues[_tokenId][highestBid][i].owner] += amountBrushClaimable;
      }
      // We consumed all orders at this price, so remove all
      if (
        numFullyConsumed == bidValues[_tokenId][highestBid].length - bids[_tokenId].getNode(highestBid).tombstoneOffset
      ) {
        bids[_tokenId].remove(highestBid);
        delete bidValues[_tokenId][highestBid];
      } else {
        // Increase tombstone offset of this price for gas efficiency
        bids[_tokenId].edit(highestBid, uint32(numFullyConsumed));
      }
    }
  }

  function takeFromOrderBook(
    bool _isBuy,
    uint _tokenId,
    uint64 _price,
    uint32 _quantity
  ) private returns (uint32 quantityRemaining, uint cost) {
    // Take as much as possible from the order book
    if (_isBuy) {
      (quantityRemaining, cost) = buyTakeFromOrderBook(_tokenId, _price, _quantity);
    } else {
      (quantityRemaining, cost) = sellTakeFromOrderBook(_tokenId, _price, _quantity);
    }
  }

  function addToBook(bool _isBuy, uint _tokenId, uint64 _price, uint32 _quantity) private {
    OrderBookEntry memory orderBookEntry = OrderBookEntry(msg.sender, _quantity, nextOrderEntryId++);
    uint64 price = _price;
    if (_isBuy) {
      // Add to the bids section
      if (!bids[_tokenId].exists(price)) {
        bids[_tokenId].insert(price);
      } else {
        uint tombstoneOffset = bids[_tokenId].getNode(price).tombstoneOffset;
        // Check if this would go over the max number of orders allowed at this price level
        if ((bidValues[_tokenId][price].length - tombstoneOffset) >= maxOrdersPerPrice) {
          // Loop until we find a suitable place to put this
          uint tick = tokenIdInfos[_tokenId].tick;
          while (true) {
            price = uint64(price - tick);
            if (!bids[_tokenId].exists(price)) {
              bids[_tokenId].insert(price);
              break;
            } else if ((bidValues[_tokenId][price].length - tombstoneOffset) >= maxOrdersPerPrice) {
              break;
            }
          }
        }
      }

      bidValues[_tokenId][price].push(orderBookEntry); // push to existing price entry
    } else {
      // Add to the asks section
      if (!asks[_tokenId].exists(price)) {
        asks[_tokenId].insert(price);
      } else {
        uint tombstoneOffset = asks[_tokenId].getNode(price).tombstoneOffset;
        // Check if this would go over the max number of orders allowed at this price level
        if ((askValues[_tokenId][price].length - tombstoneOffset) >= maxOrdersPerPrice) {
          uint tick = tokenIdInfos[_tokenId].tick;
          // Loop until we find a suitable place to put this
          while (true) {
            price = uint64(price + tick);
            if (!asks[_tokenId].exists(price)) {
              asks[_tokenId].insert(price);
              break;
            } else if ((askValues[_tokenId][price].length - tombstoneOffset) < maxOrdersPerPrice) {
              break;
            }
          }
        }
      }
      askValues[_tokenId][price].push(orderBookEntry); // push to existing price entry
    }
    emit AddedToBook(_isBuy, orderBookEntry, price);
  }

  function claimAll(uint[] calldata _tokenIds) external {
    claimTokens();
    claimNFTs(_tokenIds);
  }

  function claimTokens() public {
    uint amount = brushClaimable[msg.sender];
    if (amount > 0) {
      brushClaimable[msg.sender] = 0;
      _safeTransferFromUs(msg.sender, amount);
      emit ClaimedTokens(msg.sender);
    }
  }

  function claimNFTs(uint[] calldata _tokenIds) public {
    uint[] memory tokenIds = _tokenIds;
    uint[] memory amounts = new uint[](tokenIds.length);
    uint length;
    for (uint i = 0; i < tokenIds.length; ++i) {
      uint tokenId = tokenIds[i];
      uint amount = tokenIdsClaimable[msg.sender][tokenId];
      if (amount > 0) {
        tokenIds[length] = tokenId;
        amounts[length++] = amount;
        tokenIdsClaimable[msg.sender][tokenId] = 0;
        emit ClaimedNFTs(msg.sender, tokenId);
      }
    }

    assembly ("memory-safe") {
      mstore(tokenIds, length)
      mstore(amounts, length)
    }

    _safeBatchTransferNFTsFromUs(msg.sender, tokenIds, amounts);
  }

  function cancelOrder(OrderSide _side, uint _orderId, uint _tokenId, uint64 _price) external {
    // Loop through all of them until we hit ours.
    if (_side == OrderSide.Buy) {
      //      require(bids[_tokenId].exists(_price));
      OrderBookEntry[] storage orderBookEntries = bidValues[_tokenId][_price];
      uint begin = bids[_tokenId].getNode(_price).tombstoneOffset;
      uint index = _find(orderBookEntries, begin, orderBookEntries.length, _orderId);
      if (index == type(uint).max) {
        revert OrderNotFound();
      }

      // Send the remaining token back to them
      OrderBookEntry memory entry = orderBookEntries[index];
      _cancelOrder(orderBookEntries, _orderId, index);
      _safeTransferFromUs(msg.sender, uint(entry.quantity) * _price);
    } else {
      //      require(asks[_tokenId].exists(_price));
      OrderBookEntry[] storage orderBookEntries = askValues[_tokenId][_price];
      uint begin = asks[_tokenId].getNode(_price).tombstoneOffset;
      uint index = _find(orderBookEntries, begin, orderBookEntries.length, _orderId);
      if (index == type(uint).max) {
        revert OrderNotFound();
      }
      OrderBookEntry memory entry = orderBookEntries[index];
      _cancelOrder(orderBookEntries, _orderId, index);
      // Send the remaining NFTs back to them
      _safeTransferNFTsFromUs(msg.sender, _tokenId, entry.quantity);
    }
  }

  // TODO: editOrder
  // cancelOrders

  function allOrdersAtPrice(
    OrderSide _side,
    uint _tokenId,
    uint64 _price
  ) external view returns (OrderBookEntry[] memory orderBookEntries) {
    if (_side == OrderSide.Buy) {
      if (!bids[_tokenId].exists(_price)) {
        return orderBookEntries;
      }
      uint tombstoneOffset = bids[_tokenId].getNode(_price).tombstoneOffset;
      orderBookEntries = new OrderBookEntry[](bidValues[_tokenId][_price].length - tombstoneOffset);
      for (uint i; i < orderBookEntries.length; ++i) {
        orderBookEntries[i] = bidValues[_tokenId][_price][i + tombstoneOffset];
      }
    } else {
      if (!asks[_tokenId].exists(_price)) {
        return orderBookEntries;
      }
      uint tombstoneOffset = asks[_tokenId].getNode(_price).tombstoneOffset;
      orderBookEntries = new OrderBookEntry[](askValues[_tokenId][_price].length - tombstoneOffset);
      for (uint i; i < orderBookEntries.length; ++i) {
        orderBookEntries[i] = askValues[_tokenId][_price][i + tombstoneOffset];
      }
    }
  }

  function _sendFees(uint _tokenId, uint _cost) private returns (uint) {
    uint fees = 0;
    if (_cost > 0) {
      if (supportsERC2981) {
        // Transfer royalty
        (address recipient, uint amountRoyaltyFee) = IERC2981(address(nft)).royaltyInfo(_tokenId, _cost);
        if (amountRoyaltyFee > 0) {
          _safeTransferFromUs(recipient, amountRoyaltyFee);
          fees += amountRoyaltyFee;
        }
      }

      // Transfer any dev fees
      uint amountDevFee = (_cost * devFee) / 10000;
      if (amountDevFee > 0) {
        _safeTransferFromUs(devAddr, amountDevFee);
        fees += amountDevFee;
      }

      // Burn any brush fees
      uint amountBurntFee = (_cost * burntFee) / 10000;
      if (amountBurntFee > 0) {
        token.burn(amountBurntFee);
        fees += amountBurntFee;
      }
    }
    return fees;
  }

  // TODO: See if iteration is less gas intensive
  function _find(OrderBookEntry[] storage data, uint begin, uint end, uint value) internal returns (uint) {
    uint len = end - begin;
    if (len == 0 || (len == 1 && data[begin].id != value)) {
      return type(uint).max;
    }
    uint mid = begin + len / 2;
    uint v = data[mid].id;
    if (value < v) {
      return _find(data, begin, mid, value);
    } else if (value > v) {
      return _find(data, mid + 1, end, value);
    }
    return mid;
  }

  function _cancelOrder(OrderBookEntry[] storage orderBookEntries, uint _orderId, uint _index) private {
    require(orderBookEntries[_index].owner == msg.sender);
    // Remove it by shifting everything else to the left
    uint length = orderBookEntries.length;
    for (uint i = _index; i < length - 1; ++i) {
      orderBookEntries[i] = orderBookEntries[i + 1];
    }
    orderBookEntries.pop();
    emit OrderCancelled(_orderId);
  }

  function _safeTransferFromUs(address _to, uint _amount) private {
    uint balance = token.balanceOf(address(this));
    if (balance < _amount) {
      _amount = balance;
    }
    token.transfer(_to, _amount);
  }

  function _safeTransferNFTsFromUs(address _to, uint _tokenId, uint _amount) private {
    nft.safeTransferFrom(address(this), _to, _tokenId, _amount, "");
  }

  function _safeBatchTransferNFTsFromUs(address _to, uint[] memory _tokenIds, uint[] memory _amounts) private {
    nft.safeBatchTransferFrom(address(this), _to, _tokenIds, _amounts, "");
  }

  function tokensClaimable(address _account) external view returns (uint) {
    return brushClaimable[_account];
  }

  function nftClaimable(address _account, uint _tokenId) external view returns (uint) {
    return tokenIdsClaimable[_account][_tokenId];
  }

  function getHighestBid(uint _tokenId) public view returns (uint64) {
    return bids[_tokenId].last();
  }

  function getLowestAsk(uint _tokenId) public view returns (uint64) {
    return asks[_tokenId].first();
  }

  function getNode(
    OrderSide _side,
    uint _tokenId,
    uint64 _price
  ) external view returns (BokkyPooBahsRedBlackTreeLibrary.Node memory) {
    if (_side == OrderSide.Buy) {
      return bids[_tokenId].getNode(_price);
    } else {
      return asks[_tokenId].getNode(_price);
    }
  }

  function setMaxOrdersPerPrice(uint16 _maxOrdersPerPrice) external onlyOwner {
    maxOrdersPerPrice = _maxOrdersPerPrice;
  }

  function setTokenIdInfos(uint[] calldata _tokenIds, TokenIdInfo[] calldata _tokenIdInfos) external onlyOwner {
    if (_tokenIds.length != _tokenIdInfos.length) {
      revert LengthMismatch();
    }

    for (uint i = 0; i < _tokenIds.length; ++i) {
      tokenIdInfos[_tokenIds[i]] = _tokenIdInfos[i];
    }

    emit SetTokenIdInfos(_tokenIds, _tokenIdInfos);
  }

  function getTick(uint _tokenId) external view returns (uint) {
    return tokenIdInfos[_tokenId].tick;
  }

  function getMinAmount(uint _tokenId) external view returns (uint) {
    return tokenIdInfos[_tokenId].minQuantity;
  }

  // solhint-disable-next-line no-empty-blocks
  function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}
}
