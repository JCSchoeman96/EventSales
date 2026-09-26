defmodule EventSales.Analytics.TimeRules do
  @moduledoc """
  Pure canonical time rules for analytics: effective clocks, business dates,
  reporting periods, and source-age freshness classification.

  Rules only — no database, cache, or side effects.
  """

  alias EventSales.Sales.Resources.{Order, Refund}

  @five_minutes_us 5 * 60 * 1_000_000
  @ten_minutes_us 10 * 60 * 1_000_000
  @day_seconds 24 * 60 * 60

  defmodule Period do
    @moduledoc """
    Half-open UTC reporting window `[start_utc, end_utc)`.
    """

    @enforce_keys [:start_utc, :end_utc]
    defstruct [:start_utc, :end_utc, :kind, :timezone]

    @type kind :: :today | :yesterday | :custom | {:rolling_days, pos_integer()}

    @type t :: %__MODULE__{
            start_utc: DateTime.t(),
            end_utc: DateTime.t(),
            kind: kind() | nil,
            timezone: String.t() | nil
          }
  end

  defmodule Freshness do
    @moduledoc """
    Pure source-age classification relative to an observation instant.
    """

    @enforce_keys [:classification, :age_microseconds, :clock_skew?]
    defstruct [:classification, :age_microseconds, :clock_skew?]

    @type classification :: :normal | :aging | :stale

    @type t :: %__MODULE__{
            classification: classification(),
            age_microseconds: non_neg_integer(),
            clock_skew?: boolean()
          }
  end

  @doc """
  Selects the sale effective instant for period placement.

  `paid_at` is preferred over `completed_at`. Does not infer financial recognition.
  """
  @spec sale_effective_at(Order.t()) ::
          {:ok, DateTime.t()} | {:error, :missing_sale_effective_time}
  def sale_effective_at(%Order{paid_at: %DateTime{} = paid_at}), do: {:ok, paid_at}

  def sale_effective_at(%Order{paid_at: nil, completed_at: %DateTime{} = completed_at}),
    do: {:ok, completed_at}

  def sale_effective_at(%Order{}), do: {:error, :missing_sale_effective_time}

  @doc """
  Selects the refund effective instant from durable source creation time.
  """
  @spec refund_effective_at(Refund.t()) ::
          {:ok, DateTime.t()} | {:error, :missing_refund_effective_time}
  def refund_effective_at(%Refund{source_created_at: %DateTime{} = source_created_at}),
    do: {:ok, source_created_at}

  def refund_effective_at(%Refund{}), do: {:error, :missing_refund_effective_time}

  @doc """
  Converts a UTC datetime into a civil date in the named IANA timezone.
  """
  @spec business_date(DateTime.t(), String.t()) :: {:ok, Date.t()} | {:error, :invalid_timezone}
  def business_date(%DateTime{} = datetime, timezone) when timezone in ["Etc/UTC", "UTC"] do
    {:ok, DateTime.to_date(datetime)}
  end

  def business_date(%DateTime{} = datetime, timezone) when is_binary(timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> {:ok, DateTime.to_date(shifted)}
      {:error, _reason} -> {:error, :invalid_timezone}
    end
  end

  def business_date(%DateTime{}, _timezone), do: {:error, :invalid_timezone}

  @doc """
  Johannesburg civil today as `[start_utc, end_utc)`.
  """
  @spec today_bounds(String.t(), DateTime.t()) ::
          {:ok, Period.t()} | {:error, :invalid_timezone}
  def today_bounds(timezone, %DateTime{} = now) do
    with {:ok, local} <- shift_zone(now, timezone) do
      civil_day_bounds(DateTime.to_date(local), timezone, :today)
    end
  end

  @doc """
  Preceding Johannesburg civil day as `[start_utc, end_utc)`.
  """
  @spec yesterday_bounds(String.t(), DateTime.t()) ::
          {:ok, Period.t()} | {:error, :invalid_timezone}
  def yesterday_bounds(timezone, %DateTime{} = now) do
    with {:ok, local} <- shift_zone(now, timezone) do
      civil_day_bounds(Date.add(DateTime.to_date(local), -1), timezone, :yesterday)
    end
  end

  @doc """
  Rolling duration window `[now - duration, now)` using exact UTC instant arithmetic.
  """
  @spec rolling_bounds(pos_integer(), DateTime.t()) :: {:ok, Period.t()}
  def rolling_bounds(days, %DateTime{} = now) when is_integer(days) and days > 0 do
    start_utc = normalize_utc(DateTime.add(now, -days * @day_seconds, :second))

    {:ok,
     %Period{
       start_utc: start_utc,
       end_utc: normalize_utc(now),
       kind: {:rolling_days, days},
       timezone: nil
     }}
  end

  @doc """
  Last seven UTC days as `[now - 7×24h, now)`.
  """
  @spec last_7_days_bounds(DateTime.t()) :: {:ok, Period.t()}
  def last_7_days_bounds(%DateTime{} = now), do: rolling_bounds(7, now)

  @doc """
  Last thirty UTC days as `[now - 30×24h, now)`.
  """
  @spec last_30_days_bounds(DateTime.t()) :: {:ok, Period.t()}
  def last_30_days_bounds(%DateTime{} = now), do: rolling_bounds(30, now)

  @doc """
  Converts inclusive-local start and exclusive-local end civil instants to UTC `[start, end)`.

  Both `start_local` and `end_local` are interpreted in `timezone` via `NaiveDateTime`.
  """
  @spec custom_civil_bounds(NaiveDateTime.t(), NaiveDateTime.t(), String.t()) ::
          {:ok, Period.t()} | {:error, :invalid_timezone | :invalid_period_bounds}
  def custom_civil_bounds(%NaiveDateTime{} = start_local, %NaiveDateTime{} = end_local, timezone)
      when is_binary(timezone) do
    with {:ok, start_utc} <- naive_to_utc(start_local, timezone),
         {:ok, end_utc} <- naive_to_utc(end_local, timezone),
         :ok <- validate_ordered(start_utc, end_utc) do
      {:ok,
       %Period{
         start_utc: normalize_utc(start_utc),
         end_utc: normalize_utc(end_utc),
         kind: :custom,
         timezone: timezone
       }}
    end
  end

  @doc """
  Returns true when `instant` lies in the half-open UTC period `[start_utc, end_utc)`.
  """
  @spec period_contains?(Period.t(), DateTime.t()) :: boolean()
  def period_contains?(%Period{start_utc: start_utc, end_utc: end_utc}, %DateTime{} = instant) do
    DateTime.compare(start_utc, instant) in [:lt, :eq] and
      DateTime.compare(instant, end_utc) == :lt
  end

  @doc """
  Source-age in microseconds from `anchor` to `now`, clamped to zero when `anchor > now`.
  """
  @spec source_age_microseconds(DateTime.t(), DateTime.t()) ::
          {non_neg_integer(), boolean()}
  def source_age_microseconds(%DateTime{} = anchor, %DateTime{} = now) do
    diff_us = DateTime.diff(now, anchor, :microsecond)

    if diff_us < 0 do
      {0, true}
    else
      {diff_us, false}
    end
  end

  @doc """
  Classifies source freshness using M1-07 thresholds on source-age.
  """
  @spec classify_source_freshness(DateTime.t(), DateTime.t()) :: Freshness.t()
  def classify_source_freshness(%DateTime{} = anchor, %DateTime{} = now) do
    {age_us, clock_skew?} = source_age_microseconds(anchor, now)

    %Freshness{
      classification: classify_age_microseconds(age_us),
      age_microseconds: age_us,
      clock_skew?: clock_skew?
    }
  end

  @doc false
  @spec freshness_classification(DateTime.t(), DateTime.t()) :: Freshness.classification()
  def freshness_classification(anchor, now) do
    classify_source_freshness(anchor, now).classification
  end

  defp civil_day_bounds(%Date{} = date, timezone, kind) do
    with {:ok, start_local} <- local_midnight(date, timezone),
         {:ok, end_local} <- local_midnight(Date.add(date, 1), timezone),
         {:ok, start_utc} <- DateTime.shift_zone(start_local, "Etc/UTC"),
         {:ok, end_utc} <- DateTime.shift_zone(end_local, "Etc/UTC"),
         :ok <- validate_ordered(start_utc, end_utc) do
      {:ok,
       %Period{
         start_utc: normalize_utc(start_utc),
         end_utc: normalize_utc(end_utc),
         kind: kind,
         timezone: timezone
       }}
    else
      {:error, :invalid_timezone} = error -> error
      {:error, _} -> {:error, :invalid_timezone}
    end
  end

  defp local_midnight(%Date{} = date, timezone) do
    naive = NaiveDateTime.new!(date, ~T[00:00:00.000000])

    case DateTime.from_naive(naive, timezone) do
      {:ok, datetime} -> {:ok, datetime}
      {:ambiguous, first, _second} -> {:ok, first}
      {:gap, _, _} -> {:error, :invalid_timezone}
      {:error, _} -> {:error, :invalid_timezone}
    end
  end

  defp naive_to_utc(%NaiveDateTime{} = naive, timezone) do
    case DateTime.from_naive(naive, timezone) do
      {:ok, local} -> DateTime.shift_zone(local, "Etc/UTC")
      {:ambiguous, first, _second} -> DateTime.shift_zone(first, "Etc/UTC")
      {:gap, _, _} -> {:error, :invalid_timezone}
      {:error, _} -> {:error, :invalid_timezone}
    end
  end

  defp shift_zone(%DateTime{} = datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> {:ok, shifted}
      {:error, _} -> {:error, :invalid_timezone}
    end
  end

  defp validate_ordered(%DateTime{} = start_utc, %DateTime{} = end_utc) do
    if DateTime.compare(start_utc, end_utc) == :lt,
      do: :ok,
      else: {:error, :invalid_period_bounds}
  end

  @spec normalize_utc(DateTime.t()) :: DateTime.t()
  defp normalize_utc(%DateTime{} = datetime) do
    {microsecond, _} = datetime.microsecond
    %{datetime | microsecond: {microsecond, 6}}
  end

  defp classify_age_microseconds(age_us) when age_us < @five_minutes_us, do: :normal
  defp classify_age_microseconds(age_us) when age_us <= @ten_minutes_us, do: :aging
  defp classify_age_microseconds(_age_us), do: :stale
end
