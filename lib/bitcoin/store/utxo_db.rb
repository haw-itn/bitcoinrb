require 'leveldb-native'

module Bitcoin
  module Store
    class UtxoDB

      KEY_PREFIX = {
        out_point: 'o',        # key: out_point(tx_hash and index), value: Utxo
        script: 's',           # key: script_pubkey and out_point(tx_hash and index), value: Utxo
        tx_hash: 't',          # key: tx_hash of transaction, value: [block_height, tx_index]
        tx_payload: 'p',       # key: tx_hash, value: Tx
      }

      attr_reader :level_db, :logger

      def initialize(path = "#{Bitcoin.base_dir}/db/utxo")
        FileUtils.mkdir_p(path)
        @level_db = ::LevelDBNative::DB.new(path)
        @logger = Bitcoin::Logger.create(:debug)
      end

      def close
        level_db.close
      end

      # Save payload of a transaction into db
      #
      # @param  [String] tx_hash
      # @param  [String] tx_payload
      def save_tx(tx_hash, tx_payload)
        logger.info("UtxoDB#save_tx:#{[tx_hash, tx_payload]}")
        level_db.batch do
          # tx_hash -> [block_height, tx_index]
          key = KEY_PREFIX[:tx_payload] + tx_hash
          level_db.put(key, tx_payload)
        end
      end

      # Save tx position (block height and index in the block) into db
      # When node receives `header` message, node should call save_tx_position to store block height and its index.
      #
      # @param  [String] tx_hash
      # @param  [Integer] block_height
      # @param  [Integer] tx_index
      def save_tx_position(tx_hash, block_height, tx_index)
        logger.info("UtxoDB#save_tx_position:#{[tx_hash, block_height, tx_index]}")
        level_db.batch do
          # tx_hash -> [block_height, tx_index]
          key = KEY_PREFIX[:tx_hash] + tx_hash
          level_db.put(key, [block_height, tx_index].pack('N2').bth)

          update_utxo_height(tx_hash, block_height)
        end
      end

      # Save utxo into db
      #
      # @param [Bitcoin::OutPoint] out_point
      # @param [Double] value
      # @param [Bitcoin::Script] script_pubkey
      # @param [Integer] block_height
      def save_utxo(out_point, value, script_pubkey, block_height=nil)
        logger.info("UtxoDB#save_utxo:#{[out_point, value, script_pubkey, block_height]}")
        level_db.batch do
          utxo = Bitcoin::Wallet::Utxo.new(out_point.tx_hash, out_point.index, value, script_pubkey, block_height)
          payload = utxo.to_payload

          # out_point
          key = KEY_PREFIX[:out_point] + out_point.to_hex
          level_db.put(key, payload)

          # script_pubkey
          if script_pubkey
            key = KEY_PREFIX[:script] + script_pubkey.to_hex + out_point.to_hex
            level_db.put(key, payload)
          end
          utxo
        end
      end

      # Update height in UTXO which have specified tx_hash
      #
      # @param [String] tx_hash
      def update_utxo_height(tx_hash, block_height)
        from = KEY_PREFIX[:out_point] + tx_hash + '00000000'
        to = KEY_PREFIX[:out_point] + tx_hash + 'ffffffff'
        # fetch utxos in tx
        utxos = level_db.each(from: from, to: to).each do |k, v|
          # update height only
          utxo = Bitcoin::Wallet::Utxo.parse_from_payload(v)
          save_utxo(Bitcoin::OutPoint.new(utxo.tx_hash, utxo.index), utxo.value, utxo.script_pubkey, block_height)
        end
      end

      # Get transaction stored via save_tx and save_tx_position
      #
      # @param  [string] tx_hash
      # @return [block_height, tx_index, tx_payload]
      def get_tx(tx_hash)
        key = KEY_PREFIX[:tx_hash] + tx_hash
        return [] unless level_db.contains?(key)
        block_height, tx_index = level_db.get(key).htb.unpack('N2')
        key = KEY_PREFIX[:tx_payload] + tx_hash
        tx_payload = level_db.get(key)
        [block_height, tx_index, tx_payload]
      end

      # Delete utxo from db
      #
      # @param  [Bitcoin::Outpoint] out_point
      # @return [Bitcoin::Wallet::Utxo] 
      def delete_utxo(out_point)
        level_db.batch do
          # [:out_point]
          key = KEY_PREFIX[:out_point] + out_point.to_hex
          return unless level_db.contains?(key)
          utxo = Bitcoin::Wallet::Utxo.parse_from_payload(level_db.get(key))
          level_db.delete(key)

          # [:script]
          if utxo.script_pubkey
            key = KEY_PREFIX[:script] + utxo.script_pubkey.to_hex + out_point.to_hex
            level_db.delete(key)
          end

          utxo
        end
      end

      # Get utxo of the specified out point
      #
      # @param  [Bitcoin::Outpoint] out_point
      # @return [Bitcoin::Wallet::Utxo]
      def get_utxo(out_point)
        level_db.batch do
          key = KEY_PREFIX[:out_point] + out_point.to_hex
          return unless level_db.contains?(key)
          return Bitcoin::Wallet::Utxo.parse_from_payload(level_db.get(key))
        end
      end

      # return [Bitcoin::Wallet::Utxo ...]
      def list_unspent(current_block_height: 9999999, min: 0, max: 9999999, addresses: nil)
        if addresses
          list_unspent_by_addresses(current_block_height, min: min, max: max, addresses: addresses)
        else
          max_height = [current_block_height - min, 0].max
          min_height = [current_block_height - max, 0].max

          # Retrieve all UTXOs in UtxoDB
          from = KEY_PREFIX[:out_point] + '000000000000000000000000000000000000000000000000000000000000000000000000'
          to = KEY_PREFIX[:out_point] + 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
          with_height(utxos_between(from, to), min_height, max_height)
        end
      end

      # @param [Bitcoin::Wallet::Account]
      # return [Bitcoin::Wallet::Utxo ...]
      def list_unspent_in_account(account, current_block_height: 9999999, min: 0, max: 9999999)
        return [] unless account

        script_pubkeys = case account.purpose
          when Bitcoin::Wallet::Account::PURPOSE_TYPE[:legacy]
            account.watch_targets.map { |t| Bitcoin::Script.to_p2pkh(t).to_hex }
          when Bitcoin::Wallet::Account::PURPOSE_TYPE[:nested_witness]
            account.watch_targets.map { |t| Bitcoin::Script.to_p2wpkh(t).to_p2sh.to_hex }
          when Bitcoin::Wallet::Account::PURPOSE_TYPE[:native_segwit]
            account.watch_targets.map { |t| Bitcoin::Script.to_p2wpkh(t).to_hex }
          end
        list_unspent_by_script_pubkeys(current_block_height, min: min, max: max, script_pubkeys: script_pubkeys)
      end

      # @param [Bitcoin::Wallet::Account]
      # return [Bitcoin::Wallet::Utxo ...]
      def get_balance(account, current_block_height: 9999999, min: 0, max: 9999999)
        list_unspent_in_account(account, current_block_height: current_block_height, min: min, max: max).sum { |u| u.value }
      end

      private

      def utxos_between(from, to)
        level_db.each(from: from, to: to).map { |k, v| Bitcoin::Wallet::Utxo.parse_from_payload(v) }
      end

      def with_height(utxos, min, max)
        utxos.select { |u| u.block_height.nil? || (u.block_height >= min && u.block_height <= max) }
      end

      def list_unspent_by_addresses(current_block_height, min: 0, max: 9999999, addresses: [])
        script_pubkeys = addresses.map { |a| Bitcoin::Script.parse_from_addr(a).to_hex }
        list_unspent_by_script_pubkeys(current_block_height, min: min, max: max, script_pubkeys: script_pubkeys)
      end

      def list_unspent_by_script_pubkeys(current_block_height, min: 0, max: 9999999, script_pubkeys: [])
        max_height = current_block_height - min
        min_height = current_block_height - max
        script_pubkeys.map do |key|
          from = KEY_PREFIX[:script] + key + '000000000000000000000000000000000000000000000000000000000000000000000000'
          to = KEY_PREFIX[:script] + key + 'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
          with_height(utxos_between(from, to), min_height, max_height)
        end.flatten
      end
    end
  end
end
