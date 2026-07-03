defmodule EventSales.Ingestion.RedisRateLimiter.Adapter do
  @moduledoc false

  @callback allow?(String.t(), keyword()) :: :ok | {:error, :rate_limited | :unavailable}
  @callback reset_for_test!() :: :ok
  @callback saturate_for_test!(String.t(), keyword()) :: :ok
end
