defmodule EventSales.Accounts.PiiPolicy do
  @moduledoc """
  Centralized customer PII visibility policy.

  This module decides whether a caller may see full, masked, or no customer
  PII. It is intentionally a plain Accounts module, not an Ash resource.
  """

  alias EventSales.Accounts.Policies
  alias EventSales.Accounts.Resources.User

  @type customer_pii_visibility :: :full | :masked | :none

  @doc """
  Returns customer PII visibility for the requested context.
  """
  @spec customer_pii_visibility(User.t() | nil, keyword()) :: customer_pii_visibility()
  def customer_pii_visibility(actor, opts \\ []) do
    case Keyword.get(opts, :context, :customer_record) do
      :customer_record -> customer_record_visibility(actor, Keyword.get(opts, :event_id))
      :aggregate -> :none
      :export -> :none
      _other -> :none
    end
  end

  @doc """
  Raw webhook payload reveal is admin-only and never affected by staff PII config.
  """
  @spec can_view_raw_payload?(User.t() | nil) :: boolean()
  def can_view_raw_payload?(actor), do: Policies.global_admin?(actor)

  @doc """
  Returns the configured staff customer PII mode, failing safe to `:masked`.
  """
  @spec staff_customer_pii_visibility() :: :masked | :full
  def staff_customer_pii_visibility do
    case Application.get_env(:event_sales, :staff_customer_pii_visibility, :masked) do
      :full -> :full
      :masked -> :masked
      _invalid -> :masked
    end
  end

  defp customer_record_visibility(actor, event_id) do
    cond do
      Policies.global_admin?(actor) ->
        :full

      Policies.global_staff?(actor) ->
        staff_customer_pii_visibility()

      event_role?(actor, event_id) ->
        :none

      true ->
        :none
    end
  end

  defp event_role?(_actor, nil), do: false

  defp event_role?(actor, event_id) do
    Policies.has_unexpired_event_grant?(actor, event_id, :event_owner) ||
      Policies.has_unexpired_event_grant?(actor, event_id, :event_staff)
  end
end
