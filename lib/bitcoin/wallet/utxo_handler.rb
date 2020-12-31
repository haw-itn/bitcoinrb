module Bitcoin
  module Wallet
    class UtxoHandler
      attr_reader :watchings, :spv, :utxo_db, :pending_blocks, :pending_txs

      # @param spv [Bitcoin::Node::SPV]
      # @utxo_db [Bitcoin::Store::UtxoDb]
      def initialize(spv, utxo_db)
        @spv = spv
        @spv.add_observer(self)
        @utxo_db = utxo_db
        @logger = Bitcoin::Logger.create(:debug)
        @pending_blocks = []
        @pending_txs = []
      end

      def update(event, data)
        @logger.debug "UtxoHandler#update: #{event}, #{data}"
        send(event, data)
      end

      private

      # Called when receiving `tx` message from the connecting peers.
      #
      # - Store utxo if the output of received tx is in the watch list
      # - Delete from utxo_db for spent output.
      def tx(data)
        tx = data.tx
        tx.outputs.each_with_index do |output, index|
          next unless watching?(output)
          out_point = Bitcoin::OutPoint.new(tx.tx_hash, index)
          utxo_db.save_utxo(out_point, output.value, output.script_pubkey)
        end

        tx.inputs.each do |input|
          utxo_db.delete_utxo(input.out_point)
        end

        pending_txs << tx
      end

      # Called when receiving `header` message from connecting peers.
      #
      # if block is contained in pending list, call save_tx_position
      def header(data)
        block_height = data[:height]
        block_hash = data[:hash]

        pending_blocks.each do |pending_merkleblock|
          tx_blockhash = pending_merkleblock.header.block_hash
          block = spv.chain.find_entry_by_hash(tx_blockhash)
          if block
            save_tx_position(pending_merkleblock, block)
            pending_blocks.delete(pending_merkleblock)
          end
        end
      end

      # Called when receiving `merkleblock` message from connecting peers.
      #
      # if spv has block:
      #     save position of the transaction,
      # otherwise:
      #     data is cached in the pending list. this data is handled when node receive `header` message.
      def merkleblock(data)
        tx_blockhash = data.header.block_hash
        block = spv.chain.find_entry_by_hash(tx_blockhash)
        if block
          save_tx_position(data, block)
        else
          pending_blocks << data
        end
      end

      # Return if specified output is contained in watch_targets
      def watching?(output)
        return false unless spv.wallet
        watch_targets = spv.wallet.watch_targets
        watch_targets.find do |target|
          output.script_pubkey.to_hex.include?(target)
        end
      end

      # Save tx position(block height, and index in the block)
      def save_tx_position(data, block)
        tree = Bitcoin::MerkleTree.build_partial(data.tx_count, data.hashes, Bitcoin.byte_to_bit(data.flags.htb))
        block_height = block.height
        pending_txs.each do |item|
            tx_index = tree.find_node(item.tx_hash)&.index
            next unless tx_index
            utxo_db.save_tx_position(item.tx_hash, block_height, tx_index)
            pending_txs.delete(item)
          end
      end
    end
  end
end
