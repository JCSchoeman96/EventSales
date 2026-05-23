defmodule EventSales.Ingestion.Validations.ScopedManualSync do
  @moduledoc false

  use Ash.Resource.Validation

  alias EventSales.Ingestion.ReconciliationPeakGuard

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, opts, context) do
    now =
      validation_now(opts, context) ||
        Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    case validate_scope(changeset) do
      :ok -> validate_peak_guard(changeset, now)
      error -> error
    end
  end

  defp validate_scope(changeset) do
    missing =
      [:event_id, :date_from, :date_to]
      |> Enum.reject(fn field ->
        value = Ash.Changeset.get_attribute(changeset, field)
        not is_nil(value)
      end)

    case missing do
      [] ->
        date_from = Ash.Changeset.get_attribute(changeset, :date_from)
        date_to = Ash.Changeset.get_attribute(changeset, :date_to)

        if DateTime.compare(date_to, date_from) == :gt do
          :ok
        else
          {:error, field: :date_to, message: "must be after date_from"}
        end

      [field | _] ->
        {:error, field: field, message: "is required"}
    end
  end

  defp validate_peak_guard(changeset, now) do
    sync_mode = Ash.Changeset.get_attribute(changeset, :sync_mode)
    date_from = Ash.Changeset.get_attribute(changeset, :date_from)
    date_to = Ash.Changeset.get_attribute(changeset, :date_to)

    case ReconciliationPeakGuard.validate(sync_mode, date_from, date_to, now: now) do
      :ok ->
        :ok

      {:error, :peak_restricted} ->
        {:error, field: :sync_mode, message: "deep sync is not allowed during peak weekdays"}

      {:error, :date_range_too_wide} ->
        {:error, field: :date_to, message: "date range is too wide during peak weekdays"}
    end
  end

  defp validation_now(_opts, %Ash.Resource.Validation.Context{
         source_context: %{scoped_manual_sync_now: %DateTime{} = dt}
       }) do
    dt
  end

  defp validation_now(_opts, %Ash.Resource.Validation.Context{
         source_context: %{private: %{scoped_manual_sync_now: %DateTime{} = dt}}
       }) do
    dt
  end

  defp validation_now(_opts, %{scoped_manual_sync_now: %DateTime{} = dt}), do: dt
  defp validation_now(_opts, %{private: %{scoped_manual_sync_now: %DateTime{} = dt}}), do: dt
  defp validation_now(_opts, _), do: nil
end
