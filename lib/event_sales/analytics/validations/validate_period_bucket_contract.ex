defmodule EventSales.Analytics.Validations.ValidatePeriodBucketContract do
  @moduledoc false

  use Ash.Resource.Validation

  @bucket_timezones %{
    utc_hour: "UTC",
    johannesburg_day: "Africa/Johannesburg"
  }

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    bucket_kind = Ash.Changeset.get_attribute(changeset, :bucket_kind)
    bucket_timezone = Ash.Changeset.get_attribute(changeset, :bucket_timezone)
    bucket_start_utc = Ash.Changeset.get_attribute(changeset, :bucket_start_utc)
    bucket_end_utc = Ash.Changeset.get_attribute(changeset, :bucket_end_utc)

    with :ok <- validate_timezone(bucket_kind, bucket_timezone) do
      validate_bounds(bucket_start_utc, bucket_end_utc)
    end
  end

  defp validate_timezone(nil, _bucket_timezone), do: :ok
  defp validate_timezone(_bucket_kind, nil), do: :ok

  defp validate_timezone(bucket_kind, bucket_timezone) do
    case Map.fetch(@bucket_timezones, bucket_kind) do
      {:ok, ^bucket_timezone} ->
        :ok

      {:ok, _expected_timezone} ->
        {:error,
         field: :bucket_timezone, message: "does not match the timezone required by bucket_kind"}

      :error ->
        :ok
    end
  end

  defp validate_bounds(nil, _bucket_end_utc), do: :ok
  defp validate_bounds(_bucket_start_utc, nil), do: :ok

  defp validate_bounds(bucket_start_utc, bucket_end_utc) do
    if DateTime.compare(bucket_start_utc, bucket_end_utc) == :lt do
      :ok
    else
      {:error, field: :bucket_end_utc, message: "must be after bucket_start_utc"}
    end
  end
end
