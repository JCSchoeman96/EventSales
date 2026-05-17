defmodule EventSales.Catalog.ProductMetadataCache do
  @moduledoc """
  Short-lived, informational WooCommerce product metadata cache.

  This cache is owned by a supervised GenServer and stores bounded metadata in
  ETS. Cached metadata is recovery context only; it must never decide
  `event_id`, `ticket_type_id`, or create `ProductMapping` records.
  """

  use GenServer

  alias EventSales.Telemetry

  @default_ttl_ms :timer.minutes(20)
  @table __MODULE__.Table
  @fields [
    :source_system_id,
    :woo_product_id,
    :woo_variation_id,
    :name,
    :product_type,
    :status,
    :fetched_at,
    :expires_at
  ]

  @type key :: {Ecto.UUID.t() | String.t(), integer(), integer() | nil}
  @type metadata :: %{
          required(:source_system_id) => Ecto.UUID.t() | String.t(),
          required(:woo_product_id) => integer(),
          required(:woo_variation_id) => integer() | nil,
          required(:name) => String.t() | nil,
          required(:product_type) => String.t() | nil,
          required(:status) => String.t() | nil,
          required(:fetched_at) => DateTime.t(),
          required(:expires_at) => DateTime.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Reads a cached product metadata entry, returning `:miss` for missing or expired keys."
  @spec get(Ecto.UUID.t() | String.t(), integer(), integer() | nil) :: {:ok, metadata()} | :miss
  def get(source_system_id, woo_product_id, woo_variation_id \\ nil) do
    GenServer.call(__MODULE__, {:get, key(source_system_id, woo_product_id, woo_variation_id)})
  end

  @doc "Stores bounded metadata under its source/product/variation key."
  @spec put(map(), keyword()) :: :ok | {:error, :invalid_metadata}
  def put(metadata, opts \\ [])

  def put(metadata, opts) when is_map(metadata) do
    with {:ok, sanitized} <- sanitize_metadata(metadata, opts) do
      GenServer.call(__MODULE__, {:put, key_from_metadata(sanitized), sanitized})
    end
  end

  def put(_metadata, _opts), do: {:error, :invalid_metadata}

  @doc "Invalidates a single product metadata cache key."
  @spec invalidate(Ecto.UUID.t() | String.t(), integer(), integer() | nil) :: :ok
  def invalidate(source_system_id, woo_product_id, woo_variation_id \\ nil) do
    GenServer.call(
      __MODULE__,
      {:invalidate, key(source_system_id, woo_product_id, woo_variation_id)}
    )
  end

  @doc "Deletes all expired entries from the ETS table."
  @spec cleanup_expired() :: :ok
  def cleanup_expired do
    GenServer.call(__MODULE__, :cleanup_expired)
  end

  @doc false
  @spec reset_for_test!() :: :ok
  def reset_for_test! do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    :ets.new(table, [:set, :protected, :named_table, read_concurrency: true])
    {:ok, %{table: table}}
  end

  @impl true
  def handle_call({:get, key}, _from, state) do
    reply =
      case :ets.lookup(state.table, key) do
        [{^key, metadata}] ->
          if expired?(metadata) do
            :ets.delete(state.table, key)
            emit_cache(:miss)
            :miss
          else
            emit_cache(:hit)
            {:ok, metadata}
          end

        [] ->
          emit_cache(:miss)
          :miss
      end

    {:reply, reply, state}
  end

  def handle_call({:put, key, metadata}, _from, state) do
    :ets.insert(state.table, {key, metadata})
    emit_cache(:put)
    {:reply, :ok, state}
  end

  def handle_call({:invalidate, key}, _from, state) do
    :ets.delete(state.table, key)
    {:reply, :ok, state}
  end

  def handle_call(:cleanup_expired, _from, state) do
    now = DateTime.utc_now()

    state.table
    |> :ets.tab2list()
    |> Enum.each(fn {key, metadata} ->
      if DateTime.compare(metadata.expires_at, now) != :gt do
        :ets.delete(state.table, key)
      end
    end)

    {:reply, :ok, state}
  end

  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(state.table)
    {:reply, :ok, state}
  end

  defp sanitize_metadata(metadata, opts) do
    with {:ok, source_system_id} <- fetch_required(metadata, :source_system_id),
         {:ok, woo_product_id} <- fetch_required(metadata, :woo_product_id),
         true <- is_integer(woo_product_id) and woo_product_id > 0 do
      now = DateTime.utc_now()
      ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

      metadata =
        metadata
        |> Map.take(@fields)
        |> Map.put(:source_system_id, source_system_id)
        |> Map.put(:woo_product_id, woo_product_id)
        |> Map.put_new(:woo_variation_id, nil)
        |> Map.put_new(:name, nil)
        |> Map.put_new(:product_type, nil)
        |> Map.put_new(:status, nil)
        |> Map.put_new(:fetched_at, now)
        |> Map.put(
          :expires_at,
          Map.get(metadata, :expires_at) || DateTime.add(now, ttl_ms, :millisecond)
        )

      {:ok, metadata}
    else
      _ -> {:error, :invalid_metadata}
    end
  end

  defp fetch_required(metadata, key) do
    case Map.fetch(metadata, key) do
      {:ok, value} when not is_nil(value) -> {:ok, value}
      _ -> {:error, :missing}
    end
  end

  defp expired?(metadata), do: DateTime.compare(metadata.expires_at, DateTime.utc_now()) != :gt

  defp key_from_metadata(metadata),
    do: key(metadata.source_system_id, metadata.woo_product_id, metadata.woo_variation_id)

  defp key(source_system_id, woo_product_id, woo_variation_id),
    do: {source_system_id, woo_product_id, woo_variation_id}

  defp emit_cache(cache) do
    Telemetry.emit(Telemetry.product_metadata_cache_event(cache), %{count: 1}, %{
      source: :woocommerce,
      cache: cache
    })
  end
end
