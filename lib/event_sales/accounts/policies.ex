defmodule EventSales.Accounts.Policies do
  @moduledoc """
  Authorization helper API for global roles and UUID-scoped event grants.

  These helpers always read roles and grants from Postgres. Session data may
  identify a user, but it is never trusted as an authorization source.
  """

  alias EventSales.Accounts.Resources.User
  alias EventSales.Repo

  @global_roles [:admin, :staff]
  @event_roles [:event_owner, :event_staff]

  @doc """
  Returns true when the user has the global `admin` role.
  """
  @spec global_admin?(User.t() | nil) :: boolean()
  def global_admin?(user), do: has_global_role?(user, :admin)

  @doc """
  Returns true when the user has the global `staff` role.
  """
  @spec global_staff?(User.t() | nil) :: boolean()
  def global_staff?(user), do: has_global_role?(user, :staff)

  @doc """
  Returns true when an active, unexpired event grant exists for the role.
  """
  @spec has_event_role?(User.t() | nil, Ecto.UUID.t(), atom()) :: boolean()
  def has_event_role?(user, event_id, role), do: has_unexpired_event_grant?(user, event_id, role)

  @doc """
  Checks whether a user has an active event grant that has not expired.
  """
  @spec has_unexpired_event_grant?(User.t() | nil, Ecto.UUID.t(), atom()) :: boolean()
  def has_unexpired_event_grant?(%User{id: user_id}, event_id, role) when role in @event_roles do
    case Ecto.UUID.cast(event_id) do
      {:ok, event_uuid} ->
        now = DateTime.utc_now()

        %{rows: [[count]]} =
          Repo.query!(
            """
            SELECT count(*)
            FROM accounts_event_access_grants
            WHERE user_id = $1
              AND event_id = $2
              AND role = $3
              AND active = TRUE
              AND (expires_at IS NULL OR expires_at > $4)
            """,
            [dump_uuid!(user_id), dump_uuid!(event_uuid), Atom.to_string(role), now]
          )

        count > 0

      :error ->
        false
    end
  end

  def has_unexpired_event_grant?(_user, _event_id, _role), do: false

  @doc """
  Revenue visibility is admin-true by default; event roles consult dashboard settings.
  """
  @spec can_view_revenue?(User.t() | nil, Ecto.UUID.t()) :: boolean()
  def can_view_revenue?(user, event_id) do
    cond do
      global_admin?(user) ->
        true

      has_unexpired_event_grant?(user, event_id, :event_owner) &&
          dashboard_setting_allows?(event_id, :revenue_visible_to_event_owner) ->
        true

      has_unexpired_event_grant?(user, event_id, :event_staff) &&
          dashboard_setting_allows?(event_id, :revenue_visible_to_event_staff) ->
        true

      true ->
        false
    end
  end

  @doc """
  Returns true when an actor may read aggregate dashboard data for the event.
  """
  @spec can_access_event_dashboard?(User.t() | nil, Ecto.UUID.t()) :: boolean()
  def can_access_event_dashboard?(user, event_id) do
    not is_nil(event_dashboard_role(user, event_id))
  end

  @doc """
  Returns the dashboard role that authorizes event aggregate access.
  """
  @spec event_dashboard_role(User.t() | nil, Ecto.UUID.t()) ::
          :admin | :event_owner | :event_staff | nil
  def event_dashboard_role(user, event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, event_uuid} ->
        event_dashboard_role_for_uuid(user, event_uuid)

      :error ->
        nil
    end
  end

  defp event_dashboard_role_for_uuid(user, event_id) do
    cond do
      global_admin?(user) -> :admin
      has_unexpired_event_grant?(user, event_id, :event_owner) -> :event_owner
      has_unexpired_event_grant?(user, event_id, :event_staff) -> :event_staff
      true -> nil
    end
  end

  @spec has_global_role?(User.t() | nil, atom()) :: boolean()
  defp has_global_role?(%User{id: user_id}, role) when role in @global_roles do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM accounts_user_roles AS user_roles
        INNER JOIN accounts_roles AS roles ON roles.id = user_roles.role_id
        WHERE user_roles.user_id = $1
          AND roles.name = $2
        """,
        [dump_uuid!(user_id), Atom.to_string(role)]
      )

    count > 0
  end

  defp has_global_role?(_user, _role), do: false

  defp dashboard_setting_allows?(event_id, :revenue_visible_to_event_owner) do
    dashboard_flag?(event_id, "revenue_visible_to_event_owner")
  end

  defp dashboard_setting_allows?(event_id, :revenue_visible_to_event_staff) do
    dashboard_flag?(event_id, "revenue_visible_to_event_staff")
  end

  defp dashboard_flag?(event_id, column)
       when column in ["revenue_visible_to_event_owner", "revenue_visible_to_event_staff"] do
    case Ecto.UUID.cast(event_id) do
      {:ok, event_uuid} ->
        {:ok, dumped_event_id} = Ecto.UUID.dump(event_uuid)

        now = DateTime.utc_now()

        case Repo.query!(
               """
               SELECT #{column}
               FROM catalog_event_dashboard_settings
               WHERE event_id = $1
                 AND (access_expires_at IS NULL OR access_expires_at > $2)
               """,
               [dumped_event_id, now]
             ) do
          %{rows: [[true]]} -> true
          _ -> false
        end

      :error ->
        false
    end
  end

  defp dump_uuid!(uuid) do
    {:ok, dumped_uuid} = Ecto.UUID.dump(uuid)
    dumped_uuid
  end
end
