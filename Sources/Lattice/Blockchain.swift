//import Foundation
//
//public class Blockchain {
//    private var chain: [Block]
//    private var pendingTransactions: [Transaction]
//    private let difficulty: UInt32
//    private let miningReward: Double
//    
//    public var blocks: [Block] {
//        return chain
//    }
//    
//    public var latestBlock: Block? {
//        return chain.last
//    }
//    
//    public init(difficulty: UInt32 = 4, miningReward: Double = 100.0) {
//        self.chain = []
//        self.pendingTransactions = []
//        self.difficulty = difficulty
//        self.miningReward = miningReward
//        
//        createGenesisBlock()
//    }
//    
//    private func createGenesisBlock() {
//        let genesisTransaction = Transaction.createCoinbaseTransaction(to: "genesis", amount: 0)
//        let genesisBlock = Block(
//            index: 0,
//            previousHash: "",
//            transactions: [genesisTransaction],
//            difficulty: difficulty
//        )
//        chain.append(genesisBlock)
//    }
//    
//    public func addTransaction(_ transaction: Transaction) -> Bool {
//        guard transaction.isValid() else {
//            return false
//        }
//        
//        if !transaction.inputs.contains(where: { $0.transactionId == "coinbase" }) {
//            let senderBalance = getBalance(address: transaction.inputs.first?.publicKey ?? "")
//            if senderBalance < transaction.totalOutputAmount + transaction.fee {
//                return false
//            }
//        }
//        
//        pendingTransactions.append(transaction)
//        return true
//    }
//    
//    public func minePendingTransactions(miningRewardAddress: String) -> Block? {
//        let rewardTransaction = Transaction.createCoinbaseTransaction(to: miningRewardAddress, amount: miningReward)
//        var transactionsToMine = [rewardTransaction] + pendingTransactions
//        
//        let newBlock = Block(
//            index: UInt64(chain.count),
//            previousHash: latestBlock?.hash ?? "",
//            transactions: transactionsToMine,
//            difficulty: difficulty
//        )
//        
//        let minedBlock = mine(block: newBlock)
//        chain.append(minedBlock)
//        pendingTransactions.removeAll()
//        
//        return minedBlock
//    }
//    
//    private func mine(block: Block) -> Block {
//        var mutableHeader = block.header
//        let target = String(repeating: "0", count: Int(difficulty))
//        
//        while !block.hash.hasPrefix(target) {
//            mutableHeader = BlockHeader(
//                index: mutableHeader.index,
//                previousHash: mutableHeader.previousHash,
//                merkleRoot: mutableHeader.merkleRoot,
//                timestamp: mutableHeader.timestamp,
//                difficulty: mutableHeader.difficulty,
//                nonce: mutableHeader.nonce + 1
//            )
//            
//            let newBlock = Block(header: mutableHeader, transactions: block.transactions)
//            if newBlock.hash.hasPrefix(target) {
//                return newBlock
//            }
//        }
//        
//        return block
//    }
//    
//    public func getBalance(address: String) -> Double {
//        var balance: Double = 0
//        
//        for block in chain {
//            for transaction in block.transactions {
//                for input in transaction.inputs {
//                    if input.publicKey == address {
//                        balance -= transaction.totalOutputAmount + transaction.fee
//                    }
//                }
//                
//                for output in transaction.outputs {
//                    if output.address == address {
//                        balance += output.amount
//                    }
//                }
//            }
//        }
//        
//        return balance
//    }
//    
//    public func isChainValid() -> Bool {
//        for i in 1..<chain.count {
//            let currentBlock = chain[i]
//            let previousBlock = chain[i - 1]
//            
//            if !currentBlock.isValid(previousBlock: previousBlock) {
//                return false
//            }
//            
//            if currentBlock.header.previousHash != previousBlock.hash {
//                return false
//            }
//        }
//        
//        return true
//    }
//    
//    public func getTransactionHistory(address: String) -> [Transaction] {
//        var transactions: [Transaction] = []
//        
//        for block in chain {
//            for transaction in block.transactions {
//                let isInvolved = transaction.inputs.contains { $0.publicKey == address } ||
//                                transaction.outputs.contains { $0.address == address }
//                
//                if isInvolved {
//                    transactions.append(transaction)
//                }
//            }
//        }
//        
//        return transactions
//    }
//    
//    public func getPendingTransactions() -> [Transaction] {
//        return pendingTransactions
//    }
//}
