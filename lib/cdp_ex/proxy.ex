defmodule CDPEx.Proxy do
  @moduledoc """
  Parses the `:proxy` launch option into a Chrome `--proxy-server` flag plus, when the
  proxy is authenticated, the credentials `CDPEx.Browser` arms on each page.

  Accepts either a URL string or a keyword list / map:

      "http://user:pass@host:8080"
      [server: "host:8080", scheme: "http", username: "user", password: "pass"]

  In the URL form, credentials with reserved characters must be percent-encoded
  (e.g. `p@ss` → `p%40ss`); they are decoded back on parse. The keyword form takes
  credentials verbatim, so prefer it when a password contains reserved characters.

  Parsing is strict, so a malformed value fails instead of becoming another proxy: a
  URL with a path, query or fragment (an unencoded `/` in a password produces one) or
  a non-numeric port, a `:server` carrying `user:pass@`, and a non-string
  `:username`/`:password` all return `{:error, {:invalid_proxy, reason}}`. No error
  term carries the credentials.

  See the `:proxy` option on `CDPEx.launch/1`.
  """

  @typedoc """
  A parsed proxy: the `scheme://host:port` value for Chrome's `--proxy-server`
  (userinfo stripped), plus optional credentials (`nil` for an open proxy).
  """
  @type t :: %{server: String.t(), username: String.t() | nil, password: String.t() | nil}

  @doc """
  Parses a `:proxy` value into `{:ok, t}` or `{:error, {:invalid_proxy, reason}}`.
  """
  @spec parse(term()) :: {:ok, t()} | {:error, {:invalid_proxy, term()}}
  def parse(url) when is_binary(url), do: parse_url(url)

  # Any other list may hold a URL with credentials, so it is not echoed.
  def parse(opts) when is_list(opts) do
    if Keyword.keyword?(opts),
      do: parse_opts(Map.new(opts)),
      else: {:error, {:invalid_proxy, {:unsupported, :list}}}
  end

  def parse(%{} = opts), do: parse_opts(opts)
  def parse(other), do: {:error, {:invalid_proxy, {:unsupported, other}}}

  @doc "The `--proxy-server=…` Chrome flag for a parsed proxy."
  @spec to_arg(t()) :: String.t()
  def to_arg(%{server: server}), do: "--proxy-server=#{server}"

  @doc """
  Credentials (`%{username, password}`) when the proxy needs auth, else `nil`.

  Both parts must be present and non-empty; a missing or empty half is treated as no
  auth (the proxy is used unauthenticated).
  """
  @spec credentials(t()) :: %{username: String.t(), password: String.t()} | nil
  def credentials(%{username: u, password: p}) when is_binary(u) and is_binary(p),
    do: %{username: u, password: p}

  def credentials(_), do: nil

  # Strict: a proxy URL is `scheme://[userinfo@]host[:port]` and nothing else. A path,
  # query or fragment means the string was not what it looked like (an unencoded `/` in
  # a password makes "http://user:pa/ss@host:8080" a URL for host "user"), and a lax
  # parse would hand Chrome a different proxy without an error.
  defp parse_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, port: port, path: path} = uri}
      when is_binary(scheme) and is_binary(host) and host != "" and is_integer(port) and
             path in [nil, "", "/"] and is_nil(uri.query) and is_nil(uri.fragment) ->
        {user, pass} = split_userinfo(uri.userinfo)

        {:ok,
         %{server: "#{scheme}://#{host_for_server(host)}:#{port}", username: user, password: pass}}

      _ ->
        {:error, {:invalid_proxy, {:malformed_url, redact(url)}}}
    end
  end

  defp parse_opts(%{server: server} = opts) when is_binary(server) and server != "" do
    server = if String.contains?(server, "://"), do: server, else: "#{scheme(opts)}://#{server}"
    bad = for key <- [:username, :password], not credential?(opts[key]), do: key

    cond do
      # Chrome would get them on its command line, and no login would be armed.
      String.contains?(server, "@") ->
        {:error, {:invalid_proxy, :credentials_in_server}}

      bad != [] ->
        {:error, {:invalid_proxy, {:invalid_credentials, bad}}}

      true ->
        {:ok,
         %{
           server: server,
           username: blank_to_nil(opts[:username]),
           password: blank_to_nil(opts[:password])
         }}
    end
  end

  # Echo only the keys, never the values — opts may carry :password.
  defp parse_opts(opts), do: {:error, {:invalid_proxy, {:missing_server, Map.keys(opts)}}}

  defp scheme(opts), do: Map.get(opts, :scheme, "http")

  defp credential?(value), do: is_nil(value) or is_binary(value)

  # Mask everything up to the last "@" (keeping a leading scheme) so a credentialed
  # proxy string never lands in an error term or a status (these surface from launch/1,
  # and callers routinely log them), however malformed it is: with no scheme, or with an
  # unencoded "@" in the password.
  defp redact(url) when is_binary(url) do
    case String.split(url, "@") do
      [_no_userinfo] ->
        url

      parts ->
        scheme =
          case Regex.run(~r{\A[A-Za-z][A-Za-z0-9+.-]*://}, url) do
            [scheme] -> scheme
            nil -> ""
          end

        scheme <> "***@" <> List.last(parts)
    end
  end

  @doc false
  # A `:proxy` option value with its credentials masked, for crash reports and
  # process status: the URL loses its userinfo, the keyword and map forms their username
  # and password (and any userinfo in :server). Anything else comes back unchanged.
  @spec redact_option(term()) :: term()
  def redact_option(url) when is_binary(url), do: redact(url)

  def redact_option(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: Enum.map(opts, &redact_pair/1), else: opts
  end

  def redact_option(%{} = opts), do: Map.new(opts, &redact_pair/1)
  def redact_option(other), do: other

  defp redact_pair({key, value}) when key in [:username, :password] and value != nil,
    do: {key, "***"}

  defp redact_pair({:server, server}) when is_binary(server), do: {:server, redact(server)}
  defp redact_pair(pair), do: pair

  # URI strips the brackets from an IPv6 literal (host: "::1"); re-wrap so the rebuilt
  # `host:port` stays unambiguous for Chrome (`[::1]:8080`, not `::1:8080`).
  defp host_for_server(host) do
    if String.contains?(host, ":"), do: "[#{host}]", else: host
  end

  # URI keeps userinfo encoded; decode the parts so a percent-encoded password round-trips.
  # An empty user/password is treated as absent (nil) so credentials/1 reads it as no auth.
  defp split_userinfo(nil), do: {nil, nil}

  defp split_userinfo(info) do
    case String.split(info, ":", parts: 2) do
      [user, pass] -> {blank_to_nil(URI.decode(user)), blank_to_nil(URI.decode(pass))}
      [user] -> {blank_to_nil(URI.decode(user)), nil}
    end
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
