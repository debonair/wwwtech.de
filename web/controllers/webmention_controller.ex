defmodule Wwwtech.WebmentionController do
  use Wwwtech.Web, :controller

  alias Wwwtech.Note
  alias Wwwtech.Picture
  alias Wwwtech.Article
  alias Wwwtech.Mention

  def mention(conn, params) do
    case is_valid_mention(conn, params) do
      :ok ->
        save_valid_mention(conn, params)
      {:error, nconn} ->
        nconn
    end
  end

  def save_valid_mention(conn, params) do
    {object, type} = case Regex.run(~r/(notes|pictures|articles)\/(.*)/, params["target"]) do
                       [_, module, id] ->
                         {object_by_module(module, id), module}
                       _val ->
                         {nil, nil}
                     end

    if object == nil and type != nil do
      conn |> send_resp(400, "This is not the host you're looking for (object could not be found)")
      raise :return
    end

    parsed = values_from_remote(params["source"])

    old_mention = case Mention |> Mention.by_source_and_target(parsed["url"], params["target"]) |> Repo.one do
                    nil ->
                      %Mention{}
                    obj ->
                      obj
                  end

    attributes = %{source_url: parsed["url"],
                   target_url: params["target"],
                   mention_type: parsed["mention_type"] || "reply",
                   author: parsed["author"],
                   author_avatar: parsed["author_avatar"],
                   author_url: parsed["author_url"],
                   title: parsed["title"],
                   excerpt: parsed["excerpt"]}

    changeset = Mention.changeset(old_mention || %Mention{},
                                  object_id_with_key(attributes, type, object))

    if old_mention.id == nil do
      Repo.insert!(changeset)
    else
      Repo.update!(changeset)
    end

    :gen_smtp_client.send({"cjk@defunct.ch", ["cjk@defunct.ch"],
                           "Subject: [WWWTech] New Mention\r\nFrom: Christian Kruse <cjk@defunct.ch>\r\nTo: Christian Kruse <cjk@defunct.ch>\r\n\r\nSource: #{params["source"]}\r\nTarget: #{params["target"]}"},
                          [{:relay, Application.get_env(:wwwtech, :smtp_server)},
                           {:username, to_char_list(Application.get_env(:wwwtech, :smtp_user))},
                           {:password, to_char_list(Application.get_env(:wwwtech, :smtp_password))}])

    conn |> send_resp(201, "Accepted")
  end

  def is_valid_mention(conn, params) do
    if String.strip(to_string(params["target"])) == "" do
      {:error, (conn |> send_resp(400, "This is not the host you're looking for (target is blank)"))}
    else
      if String.strip(to_string(params["source"])) == "" do
        {:error, (conn |> send_resp(400, "This is not the host you're looking for (source is blank)"))}
      else
        target_uri = URI.parse(params["target"])
        my_uri = URI.parse(page_url(conn, :index))

        if target_uri.host != my_uri.host do
          {:error, (conn |> send_resp(400, "This is not the host you're looking for (host is not equal to my host)"))}
        else
          if Webmentions.is_valid_mention(params["source"], params["target"]) do
            :ok
          else
            {:error, (conn |> send_resp(400, "This is not the host you're looking for (mention is not valid)"))}
          end
        end
      end
    end
  end

  defp object_id_with_key(attributes, type, object) do
    case type do
      "notes" ->
        Map.put(attributes, :note_id, object.id)
      "pictures" ->
        Map.put(attributes, :picture_id, object.id)
      "articles" ->
        Map.put(attributes, :article_id, object.id)
      _ ->
        attributes
    end
  end

  def object_by_module(module, id) do
    case module do
      "articles" ->
        Article |>
          Article.by_slug(id) |>
          Article.only_visible(false) |>
          Repo.one!
      "notes" ->
        Repo.get!(Note, id)
      "pictures" ->
        Repo.get!(Picture, id)
      _ ->
        nil
    end
  end

  defp values_from_remote(url) do
    response = HTTPotion.get url

    if HTTPotion.Response.success?(response) do
      mf = Microformats2.parse(response.body, url)

      cond do
        Enum.count(mf[:items]) > 0 ->
          item = List.first(mf[:items])
          %{"author" => get_value(item, :author),
            "author_url" => get_sub_key(item, :author, :url),
            "author_avatar" => get_sub_key(item, :author, :photo),
            "title" => get_value(item, :name),
            "excerpt" => get_excerpt(item),
            "mention_type" => guess_mention_type(item),
            "url" => get_url(url, mf)}
        true ->
          get_values_from_html(url, response.body)
      end
    else
      %{}
    end
  end

  def get_url(url, mf) do
    if Regex.match?(~r/brid-gy.appspot.com/, url) do
      List.first(mf[:items])[:properties][:url] |> List.first
    else
      url
    end
  end

  defp get_value(item, key) do
    kv = (item[:properties][key] || []) |> List.first
    cond do
      kv == nil ->
        nil
      is_bitstring(kv) ->
        kv
      true ->
        kv[:value]
    end
  end

  defp get_sub_key(item, key, subkey) do
    key_val = (item[:properties][key] || []) |> List.first
    cond do
      is_map(key_val) and is_map(key_val[:properties]) ->
        (key_val[:properties][subkey] || []) |> List.first
      true ->
        nil
    end
  end

  defp get_excerpt(item) do
    excerpt = (item[:properties][:content] || []) |> List.first

    cond do
      excerpt != nil and is_map(excerpt) ->
        excerpt[:text]
      excerpt != nil and is_bitstring(excerpt) ->
        excerpt
      excerpt != nil ->
        IO.inspect excerpt
      true ->
        nil
    end
  end

  defp guess_mention_type(item) do
    cond do
      get_value(item, :in_reply_to) != nil ->
        "reply"
      get_value(item, :like_of) != nil ->
        "like"
      get_value(item, :repost_of) != nil ->
        "repost"
      item[:properties][:category] != nil and ((List.first(item[:properties][:category])[:type] || []) |> List.first) == "h-card" ->
        "persontag"
      true ->
        nil
    end
  end

  defp get_values_from_html(url, html) do
    doc = Floki.parse(html)
    author = Floki.find(doc, "meta[name=author]") |> Floki.attribute("content") |> List.first
    excerpt = Floki.find(doc, "meta[name=description]") |> Floki.attribute("content") |> List.first
    title = Floki.find(doc, "meta[property='og:title']") |> Floki.attribute("content") |> List.first
    author_url = Floki.find(doc, "meta[property='og:article:author']") |> Floki.attribute("content") |> List.first
    author_avatar = Floki.find(doc, "meta[property='og:image']") |> Floki.attribute("content") |> List.first

    %{"author" => author,
      "author_url" => author_url,
      "author_avatar" => author_avatar,
      "title" => title,
      "excerpt" => excerpt,
      "mention_type" => "reply",
      "url" => url}
  end
end
