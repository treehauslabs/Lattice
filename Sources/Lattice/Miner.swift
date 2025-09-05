//import Foundation
//import Crypto
//
//public class Miner {
//    public let wallet: Wallet
//    public let difficulty: UInt32
//    private var isMining: Bool = false
//    
//    public init(wallet: Wallet, difficulty: UInt32 = 4) {
//        self.wallet = wallet
//        self.difficulty = difficulty
//    }
//    
//    public func mine(block: Block, onProgress: ((UInt64, String) -> Void)? = nil) -> Block {
//        isMining = true
//        var mutableHeader = block.header
//        let target = String(repeating: "0", count: Int(difficulty))
//        var attempts: UInt64 = 0
//        
//        print("🎯 Mining block \(block.header.index) with difficulty \(difficulty)...")
//        print("🎯 Target: \(target)")
//        
//        while isMining {
//            mutableHeader = BlockHeader(
//                index: mutableHeader.index,
//                previousHash: mutableHeader.previousHash,
//                merkleRoot: mutableHeader.merkleRoot,
//                timestamp: mutableHeader.timestamp,
//                difficulty: mutableHeader.difficulty,
//                nonce: mutableHeader.nonce + 1
//            )
//            
//            let candidateBlock = Block(header: mutableHeader, transactions: block.transactions)
//            attempts += 1
//            
//            if attempts % 1000 == 0 {
//                onProgress?(attempts, candidateBlock.hash)
//                print("⛏️  Attempt \(attempts): Hash \(candidateBlock.hash.prefix(16))...")
//            }
//            
//            if candidateBlock.hash.hasPrefix(target) {
//                print("✅ Block mined! Nonce: \(mutableHeader.nonce), Hash: \(candidateBlock.hash)")
//                isMining = false
//                return candidateBlock
//            }
//        }
//        
//        return block
//    }
//    
//    public func stopMining() {
//        print("🛑 Stopping mining...")
//        isMining = false
//    }
//    
//    public func mineBlock(blockchain: Blockchain, transactions: [Transaction] = []) -> Block? {
//        guard let latestBlock = blockchain.latestBlock else {
//            return nil
//        }
//        
//        let rewardTransaction = Transaction.createCoinbaseTransaction(to: wallet.address, amount: 50.0)
//        let allTransactions = [rewardTransaction] + transactions
//        
//        let newBlock = Block(
//            index: latestBlock.header.index + 1,
//            previousHash: latestBlock.hash,
//            transactions: allTransactions,
//            difficulty: difficulty
//        )
//        
//        return mine(block: newBlock)
//    }
//    
//    public func calculateHashRate(attempts: UInt64, timeElapsed: TimeInterval) -> Double {
//        return Double(attempts) / timeElapsed
//    }
//    
//    public static func calculateDifficulty(averageBlockTime: TimeInterval, targetBlockTime: TimeInterval, currentDifficulty: UInt32) -> UInt32 {
//        let ratio = averageBlockTime / targetBlockTime
//        
//        if ratio > 1.5 {
//            return max(1, currentDifficulty - 1)
//        } else if ratio < 0.75 {
//            return min(10, currentDifficulty + 1)
//        }
//        
//        return currentDifficulty
//    }
//    
//    public static func estimateMiningTime(difficulty: UInt32, hashRate: Double) -> TimeInterval {
//        let target = pow(16.0, Double(difficulty))
//        return target / hashRate
//    }
//}
