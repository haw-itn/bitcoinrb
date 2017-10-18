module Bitcoin
  module Network

    # remote peer class.
    class Peer

      attr_reader :logger
      attr_accessor :local_version
      # remote peer info
      attr_reader :host
      attr_reader :port
      # remote peer connection
      attr_accessor :conn
      attr_accessor :connected
      attr_accessor :primary
      # parent pool
      attr_reader :pool
      attr_reader :chain
      attr_accessor :fee_rate

      def initialize(host, port, pool)
        @host = host
        @port = port
        @pool = pool
        @chain = pool.chain
        @connected = false
        @primary = false
        @logger = Bitcoin::Logger.create(:debug)
        current_height = @chain.latest_block.height
        @local_version = Bitcoin::Message::Version.new(remote_addr: addr, start_height: current_height)
      end

      def connect
        self.conn ||= EM.connect(host, port, Bitcoin::Network::Connection, self)
      end

      def connected?
        @connected
      end

      def addr
        "#{host}:#{port}"
      end

      def post_handshake
        @connected = true
        pool.handle_new_peer(self)
        # require remote peer to use headers message instead fo inv message.
        conn.send_message(Bitcoin::Message::SendHeaders.new)
      end

      # start block header download
      def start_block_header_download
        logger.debug "[#{addr}] start block header download."
        get_headers = Bitcoin::Message::GetHeaders.new(
            Bitcoin.chain_params.protocol_version, [chain.latest_block.hash])
        conn.send_message(get_headers)
      end

      # broadcast tx.
      def broadcast_tx(tx)
        conn.send_message(Bitcoin::Message::Tx.new(tx, support_witness?))
      end

      # check the remote peer support witness.
      def support_witness?
        return false unless remote_version
        remote_version.services & Bitcoin::Message::SERVICE_FLAGS[:witness] > 0
      end

      # check the remote peer supports compact block.
      def support_cmpct?
        return false if remote_version.version < Bitcoin::Message::VERSION[:compact]
        return true unless local_version.services & Bitcoin::Message::SERVICE_FLAGS[:witness] > 0
        return false unless support_witness?
        remote_version.version >= Bitcoin::Message::VERSION[:compact_witness]
      end

      # get remote peer's version message.
      # @return [Bitcoin::Message::Version]
      def remote_version
        conn.version
      end

      # Whether to try and download blocks and transactions from this peer.
      def primary?
        primary
      end

      # handle headers message
      # @params [Bitcoin::Message::Headers]
      def handle_headers(headers)
        headers.headers.each do |header|
          break unless header.valid?
          chain.append_header(header)
        end
        start_block_header_download if headers.headers.size > 0 # next header download
      end

      # handle error
      def handle_error(e)
        pool.handle_error(e)
      end

      # close peer connection.
      def close(msg = '')
        conn.close(msg)
      end

      # generate Bitcoin::Message::NetworkAddr object from this peer info.
      # @return [Bitcoin::Message::NetworkAddr]
      def to_network_addr
        v = remote_version
        addr = Bitcoin::Message::NetworkAddr.new
        addr.time = v.timestamp
        addr.services = v.services
        addr.ip = host
        addr.port = port
        addr
      end

      # send +addr+ message to remote peer
      def send_addrs
        addrs = pool.peers.select{|p|p != self}.map(&:to_network_addr)
        conn.send_message(Bitcoin::Message::Addr.new(addrs))
      end

      # handle block inv message.
      def handle_block_inv(hashes)
        getdata = Bitcoin::Message::GetData.new(hashes.map{|h|Bitcoin::Message::Inventory.new})

      end

    end

  end
end
