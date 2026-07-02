defmodule EventSales.Maintenance.ProductionSmoke.Http do
  @moduledoc false

  @timeout_ms 15_000

  @type method :: :get | :post
  @type header :: {String.t(), String.t()}
  @type headers :: [header()]
  @type encoded_header :: {charlist(), charlist()}
  @type encoded_headers :: [encoded_header()]
  @type get_request :: {charlist(), encoded_headers()}
  @type body_request :: {charlist(), encoded_headers(), charlist(), binary()}
  @type request_tuple :: get_request() | body_request()
  @type response_header :: {String.t() | charlist(), String.t() | charlist()}
  @type response_headers :: [response_header()]
  @type request_result ::
          {:ok, non_neg_integer(), response_headers(), binary()} | {:error, term()}

  @spec request(method(), String.t(), headers(), binary() | nil, String.t()) :: request_result()
  def request(method, url, headers \\ [], body \\ nil, content_type \\ "application/octet-stream")

  def request(:get, url, headers, nil, _content_type) do
    httpc_request(:get, {String.to_charlist(url), encode_headers(headers)})
  end

  def request(:get, url, headers, body, content_type) when is_binary(body) do
    httpc_request(
      :get,
      {String.to_charlist(url), encode_headers(headers), String.to_charlist(content_type), body}
    )
  end

  def request(:post, url, headers, body, content_type) do
    httpc_request(
      :post,
      {String.to_charlist(url), encode_headers(headers), String.to_charlist(content_type),
       body || ""}
    )
  end

  @spec csrf_token!(binary()) :: binary()
  def csrf_token!(html) do
    case Regex.run(~r/name="_csrf_token"\s+value="([^"]+)"/, html, capture: :all_but_first) do
      [token] -> token
      _ -> raise EventSales.Maintenance.ProductionSmoke.Error, "admin login CSRF token missing"
    end
  end

  @spec merge_cookies(map(), response_headers()) :: map()
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

  @spec httpc_request(method(), request_tuple()) :: request_result()
  defp httpc_request(method, request) do
    raw_response = do_httpc_request(method, request)
    parse_httpc_response(raw_response)
  end

  @spec do_httpc_request(method(), request_tuple()) :: term()
  @dialyzer {:nowarn_function, do_httpc_request: 2}
  defp do_httpc_request(method, request) do
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(:httpc, :request, [
      method,
      request,
      http_options(),
      [body_format: :binary, autoredirect: false]
    ])
  end

  @spec parse_httpc_response(term()) :: request_result()
  defp parse_httpc_response({:ok, {{_version, status, _reason}, response_headers, response_body}})
       when is_integer(status) and status >= 0 and is_list(response_headers) and
              is_binary(response_body) do
    {:ok, status, response_headers, response_body}
  end

  defp parse_httpc_response({:error, reason}), do: {:error, reason}
  defp parse_httpc_response(_other), do: {:error, :invalid_httpc_response}

  @spec http_options() :: keyword()
  defp http_options do
    [
      timeout: @timeout_ms,
      connect_timeout: @timeout_ms,
      ssl: ssl_options()
    ]
  end

  @spec ssl_options() :: keyword()
  @dialyzer {:nowarn_function, ssl_options: 0}
  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  @spec encode_headers(headers()) :: encoded_headers()
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
