# frozen_string_literal: true

require_relative "CoinjarTriangleArbitrage/version"
require 'httparty'
require 'json'
require 'parallel'

module CoinjarTriangleArbitrage
  START_CURRENCY = 'GBP'
  END_CURRENCY = 'GBP'
  FIAT_DECIMAL_INITIAL_AMOUNT = 50.00
  TRADING = false
  MIN_PROFIT = 0.2
  class PublicClient
    include HTTParty
    headers {'accept' => 'application/json'}
    def initialize
    end
    def get_all_products
      request = self.class.get('https://api.exchange.coinjar.com/products',format: :plain)
      response = request.body.to_s
      # puts "all products response is #{response}"
      JSON.parse(response)
    end
    def ticker(id)
      id = id.to_s.upcase
      request = self.class.get("https://data.exchange.coinjar.com/products/#{id}/ticker",format: :plain)
      response = request.body.to_s
      # puts "ticker response is #{response} and id is #{id}"
      JSON.parse(response)
    end
  end
  class PrivateClient
    include HTTParty
    base_uri 'https://api.exchange.coinjar.com'
    headers 'Authorization' => "Bearer #{ENV['COINJAR_TRADES']}",'accept' => 'application/json','Content-Type' => 'application/json'

    def initialize
    end
    # {oid:"number"}
    def place_order(product_id,price,buy_or_sell,size,type = "LMT")
      JSON.parse(self.class.post('/orders',body: JSON.generate({"type" => type.to_s,"size" => size.to_s,"product_id" => product_id.merge.to_s,"side" => buy_or_sell.to_s,"price" => price.to_s})).to_s)
    end
    def get_order(order_id)
      JSON.parse(self.class.get("/orders/#{order_id.to_s}").to_s).to_h
    end
  end
  # a trade is simply a product of the exchange.
  class Trade
    attr_accessor :id,:name,:base,:pair,:price,:buy_precision,:sell_precision,:buy_price,:sell_price
    def initialize
    end
    def to_s
      "id:#{id} - name:#{:name} - base:#{:base} - trade:#{:pair} - buy_price:#{:buy_price} - sell_price:#{:sell_price}"
    end
  end
  class TradeFactory
    def initialize
      @public = PublicClient.new
      @all_products = @public.get_all_products
      @trades = build_trades
    end
    def build_trades
      @trades = Parallel.map(@all_products) do |product|
        trade = Trade.new
        trade.base = product["base_currency"]["iso_code"]
        trade.pair = product["counter_currency"]["iso_code"]
        trade.id = product["id"]
        trade.buy_precision = product["counter_currency"]["subunit_to_unit"].to_i.digits[1..-1].length
        trade.sell_precision = product["base_currency"]["subunit_to_unit"].to_i.digits[1..-1].length
        trade.price = @public.ticker(trade.id)["ask"].to_f
        trade.buy_price = trade.price
        trade.sell_price = 1/trade.price
        trade
      end
      return @trades
    end
  end
  class Chain
    attr_accessor :result,:trade_one,:trade_two,:trade_three,:profit,:trade_one_price,:trade_two_price,:trade_three_price,:trade_one_direction,:trade_two_direction,:trade_three_direction
    attr_reader :trade_one_quote,:trade_two_quote,:trade_three_quote
    def initialize()

    end
    #BTC/GBP - BTC base - GBP trade

    def get_quote_based_on_trade_direction(product,direction)
      # puts trade.to_s
      # puts direction.to_s
      # puts amount.to_s
      if direction == :buy
        return product.buy_price
      elsif direction == :sell
        return product.sell_price
      end
    end
    def calculate_result
      @trade_one_quote = get_quote_based_on_trade_direction(@trade_one,@trade_one_direction)
      @trade_two_quote = get_quote_based_on_trade_direction(@trade_two,@trade_two_direction)
      @trade_three_quote = get_quote_based_on_trade_direction(@trade_three,@trade_three_direction)
      @trade_one_price = @trade_one_quote * 0.999
      @trade_two_price = @trade_two_quote * 0.999
      @trade_three_price = @trade_three_quote * 0.999
      @result = @trade_one_price * @trade_two_price * @trade_three_price * FIAT_DECIMAL_INITIAL_AMOUNT
    end
    def calculate_profit
      # only valid if the start currency and end currency are the same
      @profit = @result - FIAT_DECIMAL_INITIAL_AMOUNT
    end
    def to_s
      profit = @profit
      if START_CURRENCY == END_CURRENCY
        profit = @profit.to_s
      else
        profit = "Please Manually Calculate For Now"
      end
      return "#{@trade_one.id} - trade direction: #{trade_one_direction} - price: #{@trade_one.price}
      \n
      #{@trade_two.id} - trade direction: #{@trade_two_direction} - price: #{@trade_two.price}
      \n
      #{@trade_three.id} - trade direction: #{@trade_three_direction} - price: #{@trade_three.price}
      \n
      result with fees : #{@result} - profit with all fees is = #{profit}
      \n
      ==="
    end
  end
  class ChainFactory
    def initialize
      @trades = TradeFactory.new.build_trades
      # puts "all product ids is"
      # puts @all_product_ids
      @start_currency = CoinjarTriangleArbitrage::START_CURRENCY
      @end_currency = CoinjarTriangleArbitrage::END_CURRENCY
      @start_trades = find_starting_pairs
      @end_trades = find_ending_pairs
      @intermediate_pairs = find_intermediate_pairs
    end
    def find_starting_pairs
      puts "finding start pairs"
      puts "done finding start pairs"
      return @trades.select {|trade| @start_currency == trade.base || @start_currency == trade.pair}
    end

    def find_opposing_currencies(currency)
      @start_trades.map do |trade|
        if trade.base == currency
          trade.pair
        elsif trade.pair == currency
          trade.base
        end
      end
    end

    def determine_valid_trades(start_symbols,end_symbols)
      sieved_pairs = []
      Parallel.each(start_symbols) do |symbol|
        repeated = []
        end_symbols.length.times {repeated << symbol}
        products = repeated.zip(end_symbols)
        @trades.each do |trade|
          products.each do |product|
            sieved_pairs.append(trade) if product[0] == trade.base && product[1] == trade.pair
          end
        end
      end
      return sieved_pairs
    end

    def find_intermediate_pairs
      puts "starting to find intermediate pairs"
      start_symbols = find_opposing_currencies @start_currency
      end_symbols = nil
      if @start_currency == @end_currency
        end_symbols = start_symbols
      else
        end_symbols = find_opposing_currencies @end_currency
      end
      # with thanks to Appocrathon the angel - its his algo! licenced to everyone. free and open source for all.
      sieved_pairs = []
      sieved_pairs << determine_valid_trades(start_symbols,end_symbols)
      sieved_pairs << determine_valid_trades(end_symbols,start_symbols)
      sieved_pairs.flatten!
      sieved_pairs.uniq!
      puts "done finding intermediate pairs"
      return sieved_pairs
    end

    def find_ending_pairs
      puts "finding ending pairs"
      if @start_currency == @end_currency
        return @start_trades
      else
        return @trades.select {|trade| @end_currency == trade.base || @end_currency == trade.pair}
      end

      puts "done finding ending pairs"
    end

    def find_operative_currency(trade,opposing_currency)
      trade_currency = ""
      if opposing_currency == trade.base
        trade_currency = trade.pair
      elsif opposing_currency == trade.pair
        trade_currency = trade.base
      end
      trade_currency
    end
    def build_chains
      puts "building chains now"
      chains = []
      Parallel.each(@start_trades.uniq, in_threads:@start_trades.uniq.count) do |start|
        @intermediate_pairs.each do |middle|
          middle_trade_currency_one = find_operative_currency(start,@start_currency)
          middle_trade_currency_two = find_operative_currency(middle,middle_trade_currency_one)
          end_trade = @end_trades.select {|trade| (trade.base == middle_trade_currency_two && trade.pair == @end_currency) || (trade.base == @end_currency && trade.pair == middle_trade_currency_two)}[0]
          if end_trade.nil?
            next
          end
          chain = Chain.new
          chain.trade_one = start
          chain.trade_two = middle
          chain.trade_three = end_trade
          chain.trade_one_direction = middle_trade_currency_one == start.base ? :buy : :sell
          chain.trade_two_direction = middle_trade_currency_one == middle.base ? :sell : :buy
          chain.trade_three_direction = middle_trade_currency_two == end_trade.base ? :sell : :buy
          chain.calculate_result
          chain.calculate_profit
          chains << chain
        end
      end
      puts "done building chains"
      return chains
    end


  end

  class Scout
    # include HTTParty
    # base_uri 'api.exchange.coinjar.com:443'
    # headers 'Authorization' => "Bearer #{ENV['COINJAR_TRADES']}",'accept' => 'application/json'

    def initialize
    end
    def run
      ChainFactory.new.build_chains.select { |chain| chain.profit.to_f.finite? }.max {|chain_a,chain_b| chain_a.profit.to_f <=> chain_b.profit.to_f}
    end
  end
  class Trader

    def initialize(winning_chain)
      @trading = TRADING
      @winner = winning_chain
      @client = PrivateClient.new
      @public = PublicClient.new
    end
    def get_precision(product,order_side)
      all_products = @public.get_all_products
      selected_product = all_products.select {|p| p["name"] == product.join("/")}
      # selected_product = selected_product[0]
      # puts selected_product.to_s
      if order_side == :buy
        precision = selected_product[0]["counter_currency"]
        # puts precision
        return precision["subunit_to_unit"].to_i.digits[1..-1].length
      else
        precision = selected_product[0]["base_currency"]
        # puts precision
        return precision["subunit_to_unit"].to_i.digits[1..-1].length
      end
    end
    def wait_until_filled(oid)
      order = @client.get_order(oid)
      if order == {}
        raise "response is empty"
      end
      puts order
      while order["status"] != "filled" 
        sleep 1
        puts "response is"
        puts order.to_s
      end
    end
    def run
      while @trading
        if @winner.profit >= MIN_PROFIT
          amount_one = FIAT_DECIMAL_INITIAL_AMOUNT.to_f * @winner.get_quote_based_on_trade_direction(@chain_args[:start],@chain_args[:start_trade_direction]).to_f
          amount_one = amount_one.truncate(get_precision(@chain_args[:start],@chain_args[:start_trade_direction])).to_s
          puts "amount 1 is"
          puts amount_one
          trade_one = @client.place_order(@chain_args[:start].join,@winner.trade_one_price,@chain_args[:start_trade_direction].to_s,amount_one)
          puts "trade_one is"
          puts trade_one
          wait_until_filled(trade_one["oid"])
          amount_two = trade_one["size"].to_f * @winner.get_quote_based_on_trade_direction(@chain_args[:middle],@chain_args[:middle_trade_direction]).to_f
          amount_two = amount_two.truncate(get_precision(@chain_args[:middle],@chain_args[:middle_trade_direction])).to_s
          trade_two = @client.place_order(@chain_args[:middle].join,@winner.trade_two_price,@chain_args[:middle_trade_direction].to_s,amount_two)
          puts trade_two
          wait_until_filled(trade_two["oid"])
          amount_three = trade_two["size"].to_f * @winner.get_quote_based_on_trade_direction(@chain_args[:ending],@chain_args[:ending_trade_direction]).to_f
          amount_three = amount_three.truncate(get_precision(@chain_args[:ending],@chain_args[:ending_trade_direction])).to_s
          trade_three = @client.place_order(@chain_args[:ending].join,@winner.trade_three_price,@chain_args[:ending_trade_direction].to_s,amount_three)
          puts trade_three
          wait_until_filled(trade_three["oid"])
        end
      end
    end
  end
end


winner = CoinjarTriangleArbitrage::Scout.new.run
puts winner
# CoinjarTriangleArbitrage::Trader.new(winner).run