defmodule EventSales.TestSupport.Fakes.FakeTickeraAttendeeClient do
  @moduledoc false

  @name __MODULE__

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]}
    }
  end

  def start_link(_opts) do
    Agent.start_link(fn -> %{response: {:ok, default_page_result()}, calls: []} end, name: @name)
  end

  def reset!(response) do
    Agent.update(@name, fn _ -> %{response: response, calls: []} end)
  end

  def calls do
    Agent.get(@name, fn state -> Enum.reverse(state.calls) end)
  end

  def fetch_attendees_page(site_url, _api_key, page, per_page, _opts \\ []) do
    Agent.get_and_update(@name, fn %{response: response, calls: calls} = state ->
      call = %{site_url: site_url, page: page, per_page: per_page}
      {response, %{state | calls: [call | calls]}}
    end)
    |> resolve_response(site_url, page, per_page)
  end

  defp resolve_response({:ok, _} = ok, _site_url, _page, _per_page), do: ok
  defp resolve_response({:error, _} = err, _site_url, _page, _per_page), do: err

  defp resolve_response(fun, site_url, page, per_page) when is_function(fun, 4) do
    fun.(site_url, page, per_page, calls())
  end

  defp resolve_response(other, _site_url, _page, _per_page), do: other

  defp default_page_result do
    %{
      attendees: [],
      page: 1,
      per_page: 50,
      count: 0,
      additional: %{}
    }
  end
end
