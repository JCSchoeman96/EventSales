defmodule EventSales.Ingestion.WebhookEventStore do
  @moduledoc """
  Injectable persistence boundary for `WebhookEvent` intake creates.
  """

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent

  @type attrs :: map()
  @type result :: {:ok, WebhookEvent.t()} | {:error, term()}

  @doc """
  Creates a webhook event via the configured store implementation.
  """
  @spec create_receive(attrs()) :: result()
  def create_receive(attrs) when is_map(attrs) do
    store_impl().create_receive(attrs)
  end

  defp store_impl do
    Application.get_env(:event_sales, :webhook_event_store, __MODULE__.Default)
  end

  defmodule Default do
    @moduledoc false

    @spec create_receive(map()) :: {:ok, WebhookEvent.t()} | {:error, term()}
    def create_receive(attrs) do
      WebhookEvent
      |> Ash.Changeset.for_create(:receive, attrs)
      |> Ash.create(domain: Ingestion)
    end
  end
end
