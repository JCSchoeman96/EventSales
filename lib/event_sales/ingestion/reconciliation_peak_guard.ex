defmodule EventSales.Ingestion.ReconciliationPeakGuard do
  @moduledoc """
  Rejects reconciliation runs that would overload WooCommerce during peak weekdays.

  During peak weekdays, `:deep` sync mode is blocked and date ranges wider than
  `max_days` are rejected. `:shallow` sync remains allowed within the cap.
  """

  @type validate_result :: :ok | {:error, :peak_restricted | :date_range_too_wide}

  @default_weekdays [1, 2, 3, 4, 5]
  @default_max_days 7

  @spec validate(atom(), DateTime.t(), DateTime.t(), keyword()) :: validate_result()
  def validate(sync_mode, date_from, date_to, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    config = Application.get_env(:event_sales, :reconciliation_peak_guard, [])

    if peak_weekday?(now, config) do
      case guard_deep_sync(sync_mode) do
        :ok -> guard_date_range(date_from, date_to, config)
        error -> error
      end
    else
      :ok
    end
  end

  defp peak_weekday?(datetime, config) do
    weekdays = Keyword.get(config, :weekdays, @default_weekdays)
    Date.day_of_week(DateTime.to_date(datetime)) in weekdays
  end

  defp guard_deep_sync(:deep), do: {:error, :peak_restricted}
  defp guard_deep_sync(_sync_mode), do: :ok

  defp guard_date_range(date_from, date_to, config) do
    max_days = Keyword.get(config, :max_days, @default_max_days)

    if date_range_days(date_from, date_to) > max_days do
      {:error, :date_range_too_wide}
    else
      :ok
    end
  end

  defp date_range_days(%DateTime{} = date_from, %DateTime{} = date_to) do
    Date.diff(DateTime.to_date(date_to), DateTime.to_date(date_from))
  end
end
