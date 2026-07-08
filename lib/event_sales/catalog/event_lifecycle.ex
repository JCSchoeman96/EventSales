defmodule EventSales.Catalog.EventLifecycle do
  @moduledoc """
  Pure computed lifecycle classification for catalog events.
  """

  @type lifecycle :: :future | :current | :past | :unknown

  @spec classify(map(), DateTime.t()) :: lifecycle()
  def classify(event, now \\ DateTime.utc_now())

  def classify(
        %{starts_at: %DateTime{} = starts_at, ends_at: %DateTime{} = ends_at},
        %DateTime{} = now
      ) do
    cond do
      DateTime.compare(starts_at, now) == :gt ->
        :future

      DateTime.compare(ends_at, now) == :lt ->
        :past

      DateTime.compare(starts_at, now) in [:lt, :eq] and
          DateTime.compare(ends_at, now) in [:gt, :eq] ->
        :current

      true ->
        :unknown
    end
  end

  def classify(_event, %DateTime{}), do: :unknown

  @spec current_bucket?(map(), DateTime.t()) :: boolean()
  def current_bucket?(event, now \\ DateTime.utc_now()) do
    classify(event, now) in [:future, :current, :unknown]
  end

  @spec past?(map(), DateTime.t()) :: boolean()
  def past?(event, now \\ DateTime.utc_now()) do
    classify(event, now) == :past
  end
end
