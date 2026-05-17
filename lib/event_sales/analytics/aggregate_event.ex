defmodule EventSales.Analytics.AggregateEvent do
  @moduledoc """
  Post-commit analytics recompute signal for hot dashboard state.

  Aggregate events do not carry sales deltas. They identify an event scope whose
  hot summary should be recomputed from durable Postgres rows through
  `EventSales.Analytics.Aggregators.EventAggregator`.
  """

  @enforce_keys [:aggregate_event_id, :event_id, :reason, :occurred_at]
  defstruct [
    :aggregate_event_id,
    :event_id,
    :reason,
    :occurred_at,
    :source_system_id,
    :order_id,
    :source_updated_at,
    :payload_hash,
    :ticket_type_id
  ]

  @type reason :: :order_processed | :order_remapped | :mapping_changed | :manual_refresh
  @type t :: %__MODULE__{
          aggregate_event_id: String.t(),
          event_id: Ecto.UUID.t() | String.t(),
          reason: reason(),
          occurred_at: DateTime.t(),
          source_system_id: Ecto.UUID.t() | String.t() | nil,
          order_id: Ecto.UUID.t() | String.t() | nil,
          source_updated_at: DateTime.t() | nil,
          payload_hash: String.t() | nil,
          ticket_type_id: Ecto.UUID.t() | String.t() | nil
        }

  @allowed_reasons [:order_processed, :order_remapped, :mapping_changed, :manual_refresh]
  @required_fields [:aggregate_event_id, :event_id, :reason, :occurred_at]
  @optional_fields [
    :source_system_id,
    :order_id,
    :source_updated_at,
    :payload_hash,
    :ticket_type_id
  ]
  @supported_fields @required_fields ++ @optional_fields
  @string_keys Map.new(@supported_fields, &{Atom.to_string(&1), &1})

  @doc """
  Builds a validated aggregate recompute signal.

  The Slice 9.5 contract rejects caller-supplied metric deltas. Hot state must
  recompute from durable rows instead of trusting event producers for math.
  """
  @spec new(map() | t()) :: {:ok, t()} | {:error, term()}
  def new(%__MODULE__{} = event) do
    event
    |> Map.from_struct()
    |> new()
  end

  def new(attrs) when is_map(attrs) do
    attrs = normalize_keys(attrs)

    with :ok <- reject_unsupported_fields(attrs),
         :ok <- require_fields(attrs),
         {:ok, reason} <- normalize_reason(attrs.reason),
         {:ok, occurred_at} <- normalize_datetime(attrs.occurred_at, :occurred_at),
         {:ok, source_updated_at} <-
           normalize_optional_datetime(Map.get(attrs, :source_updated_at), :source_updated_at),
         :ok <- validate_non_blank(attrs.aggregate_event_id, :aggregate_event_id),
         :ok <- validate_non_blank(attrs.event_id, :event_id),
         :ok <- validate_optional_non_blank(Map.get(attrs, :payload_hash), :payload_hash) do
      {:ok,
       %__MODULE__{
         aggregate_event_id: attrs.aggregate_event_id,
         event_id: attrs.event_id,
         reason: reason,
         occurred_at: occurred_at,
         source_system_id: Map.get(attrs, :source_system_id),
         order_id: Map.get(attrs, :order_id),
         source_updated_at: source_updated_at,
         payload_hash: Map.get(attrs, :payload_hash),
         ticket_type_id: Map.get(attrs, :ticket_type_id)
       }}
    end
  end

  def new(_attrs), do: {:error, :invalid_aggregate_event}

  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {key, value} when is_binary(key) ->
        {Map.get(@string_keys, key, key), value}

      {key, value} ->
        {key, value}
    end)
  end

  defp reject_unsupported_fields(attrs) do
    unsupported =
      attrs
      |> Map.keys()
      |> Enum.reject(&(&1 in @supported_fields))
      |> Enum.sort()

    case unsupported do
      [] -> :ok
      fields -> {:error, {:unsupported_fields, fields}}
    end
  end

  defp require_fields(attrs) do
    missing =
      @required_fields
      |> Enum.reject(fn field ->
        value = Map.get(attrs, field)
        not is_nil(value) and value != ""
      end)
      |> Enum.sort()

    case missing do
      [] -> :ok
      fields -> {:error, {:missing_required_fields, fields}}
    end
  end

  defp normalize_reason(reason) when reason in @allowed_reasons, do: {:ok, reason}

  defp normalize_reason(reason) when is_binary(reason) do
    reason
    |> String.to_existing_atom()
    |> normalize_reason()
  rescue
    ArgumentError -> {:error, {:invalid_reason, reason}}
  end

  defp normalize_reason(reason), do: {:error, {:invalid_reason, reason}}

  defp normalize_optional_datetime(nil, _field), do: {:ok, nil}
  defp normalize_optional_datetime(value, field), do: normalize_datetime(value, field)

  defp normalize_datetime(%DateTime{} = value, _field), do: {:ok, value}

  defp normalize_datetime(value, field) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, {:invalid_datetime, field}}
    end
  end

  defp normalize_datetime(_value, field), do: {:error, {:invalid_datetime, field}}

  defp validate_non_blank(value, _field) when is_binary(value) and value != "", do: :ok
  defp validate_non_blank(_value, field), do: {:error, {:invalid_field, field}}

  defp validate_optional_non_blank(nil, _field), do: :ok
  defp validate_optional_non_blank(value, field), do: validate_non_blank(value, field)
end
