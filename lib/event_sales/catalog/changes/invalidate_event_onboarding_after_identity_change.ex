defmodule EventSales.Catalog.Changes.InvalidateEventOnboardingAfterIdentityChange do
  @moduledoc """
  Invalidates Event onboarding when its external Tickera identity changes.

  Business metadata and lifecycle fields intentionally do not participate.
  """

  use Ash.Resource.Change

  alias EventSales.Catalog.EventOnboarding
  alias EventSales.Catalog.Resources.Event

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, &after_event_action/2)
  end

  defp after_event_action(changeset, %Event{} = event) do
    if identity_changed?(changeset, event) do
      invalidate_event(event)
    else
      {:ok, event}
    end
  end

  defp invalidate_event(%Event{id: event_id} = event) do
    case EventOnboarding.invalidate_if_pending(event_id) do
      :ok -> {:ok, event}
      {:error, _reason} -> {:error, :event_onboarding_invalidation_failed}
    end
  end

  defp identity_changed?(changeset, %Event{} = event) do
    changeset.data.external_event_id != event.external_event_id or
      changeset.data.external_event_kind != event.external_event_kind
  end
end
