defmodule EventSales.Maintenance.ProductionSmoke.Http do
  @moduledoc false

  @timeout_ms 15_000

  @spec request(atom(), String.t(), [{String.t(), String.t()}], binary() | nil, String.t()) ::
          {:ok, non_neg_integer(), list(), binary()} | {:error, term()}
  def request(method, url, headers \\ [], body \\ nil, content_type \\ "application/octet-stream") do
    request = request_tuple(url, headers, body, content_type)

    http_options = [
      timeout: @timeout_ms,
      connect_timeout: @timeout_ms,
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]

    case :httpc.request(method, request, http_options, body_format: :binary, autoredirect: false) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok, status, response_headers, response_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec csrf_token!(binary()) :: binary()
  def csrf_token!(html) do
    case Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, html, capture: :all_but_first) do
      [token] -> token
      _ -> raise EventSales.Maintenance.ProductionSmoke.Error, "admin login CSRF token missing"
    end
  end

  @spec merge_cookies(map(), list()) :: map()
  def merge_cookies(cookies, headers) do
    Enum.reduce(headers, cookies, fn {name, value}, acc ->
      if String.downcase(to_string(name)) == "set-cookie" do
        merge_cookie(acc, value)
      else
        acc
      end
    end)
  end

  @spec cookie_header(map()) :: binary()
  def cookie_header(cookies) do
    cookies
    |> Enum.sort_by(fn {name, _value} -> name end)
    |> Enum.map_join("; ", fn {name, value} -> "#{name}=#{value}" end)
  end

  defp request_tuple(url, headers, nil, _content_type) do
    {String.to_charlist(url), encode_headers(headers)}
  end

  defp request_tuple(url, headers, body, content_type) do
    {String.to_charlist(url), encode_headers(headers), String.to_charlist(content_type), body}
  end

  defp encode_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp merge_cookie(cookies, value) do
    value
    |> to_string()
    |> String.split(";", parts: 2)
    |> hd()
    |> String.split("=", parts: 2)
    |> case do
      [cookie_name, cookie_value] -> Map.put(cookies, cookie_name, cookie_value)
      _ -> cookies
    end
  end
end
