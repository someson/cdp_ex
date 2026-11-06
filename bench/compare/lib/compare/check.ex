defmodule Compare.Check do
  @moduledoc "Checks that a probe's output is real, not just a successful call."

  @doc "A PNG: its IHDR size, and more than one colour in its first rows (not blank)."
  def png(<<0x89, "PNG\r\n", 0x1A, "\n", _len::32, "IHDR", w::32, h::32, _::binary>> = bin) do
    if byte_size(bin) > 2_000,
      do: {:ok, "#{w}x#{h} PNG, #{div(byte_size(bin), 1024)} KB"},
      else: {:fail, "#{w}x#{h} PNG of #{byte_size(bin)} B: looks blank"}
  end

  def png(other),
    do: {:fail, "not a PNG: #{inspect(binary_part(other, 0, min(16, byte_size(other))))}"}

  @doc "A PNG of exactly this size: every library must render the same viewport."
  def png(bin, {w, h}) do
    case png(bin) do
      {:ok, ev} ->
        case bin do
          <<_::binary-size(16), ^w::32, ^h::32, _::binary>> -> {:ok, ev}
          _ -> {:fail, ev <> ", expected #{w}x#{h}"}
        end

      other ->
        other
    end
  end

  def pdf(<<"%PDF-", _::binary>> = bin) when byte_size(bin) > 1_000,
    do: {:ok, "PDF, #{div(byte_size(bin), 1024)} KB"}

  def pdf(other), do: {:fail, "not a PDF (#{byte_size(other)} B)"}

  @doc "PDF/A: the XMP metadata names a PDF/A part."
  def pdfa(bin) do
    with {:ok, ev} <- pdf(bin) do
      # The XMP stream may be compressed: look in the decompressed streams too.
      text = Enum.join([bin | streams(bin)])

      case Regex.run(~r/pdfaid:part(?:=["']|>)(\d)/, text) do
        [_, part] -> {:ok, "#{ev}, PDF/A-#{part} (pdfaid:part in XMP)"}
        nil -> {:fail, "PDF without PDF/A metadata"}
      end
    end
  end

  @doc """
  A header/footer was drawn: the PDF printed with the templates has more text
  operations than the same page printed without them. Chrome draws glyph ids,
  so the header's words can't be searched for directly.
  """
  def pdf_header(with_header, without) do
    with {:ok, ev} <- pdf(with_header) do
      a = text_ops(with_header)
      b = text_ops(without)

      if a > b,
        do: {:ok, "#{ev}; #{a} text operations with the templates, #{b} without"},
        else: {:fail, "#{a} text operations with the templates, #{b} without"}
    end
  end

  defp text_ops(bin),
    do: bin |> streams() |> Enum.map(&length(Regex.scan(~r/\bT[jJ]\b/, &1))) |> Enum.sum()

  defp streams(bin) do
    ~r/stream\r?\n(.*?)\r?\nendstream/s
    |> Regex.scan(bin, capture: :all_but_first)
    |> Enum.map(fn [s] ->
      try do
        :zlib.uncompress(s)
      rescue
        _ -> s
      end
    end)
  end
end
