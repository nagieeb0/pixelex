if Code.ensure_loaded?(Phoenix.Component) do
  defmodule Pixelex.Pixels do
    @moduledoc """
    The browser half of an ad pixel, rendered from the ids a tenant already
    saved.

        # root layout, once
        <Pixelex.Pixels.tags site_id={@site_id} consent={@consent} />

    A merchant pastes a Meta pixel id into `Pixelex.Dashboard.Settings` and
    their pixel starts firing. No deploy, no snippet in a template, no second
    place to keep the id.

    ## Why a library that avoids client bytes ships this

    pixelex measures **its own** analytics server-side, and that does not
    change: `Pixelex.Plug` still counts page views with nothing for a blocker
    to block. These tags are not that. They are the *advertiser's* pixels,
    talking to Meta and TikTok, and they exist because:

      * **A pixel id alone cannot reach the Conversions API.** Meta will not
        accept a call from your server authenticated by a pixel id — that is
        what the access token is. So a tenant with only an id had, until this
        module, no way to get any value out of pixelex at all. Now an id alone
        gets them exactly what a Shopify-style platform gives them, and the
        token upgrades it rather than gating it.
      * **The browser leg carries signals the server does not have.** `fbp`,
        the real user agent, the viewport. Meta's match quality is measurably
        better with both legs than with either alone, which is the entire
        premise of `Pixelex.Destinations` sharing one `event_id` — a design
        that assumed a browser leg the library never provided.

    These scripts are third-party and blockable. That is the point of the
    server leg, not an argument against this one.

    ## Ids are validated before they reach a `<script>`

    A stored id is written into JavaScript, so it is a script-injection
    boundary. Every value is checked against `[A-Za-z0-9._-]{1,64}` and a
    platform whose id fails is silently skipped. That charset admits every real
    id — digits for Meta, `G-…` for GA4, a UUID for Snapchat, `a2_…` for
    Reddit — and admits no quote, angle bracket, backslash or whitespace.

    ## Consent

    Pass the signals from `Pixelex.Plug.Context` and nothing renders when
    `Pixelex.Consent.destinations_allowed?/1` refuses. Omit it and the tags
    render — the same posture as `Pixelex.Destinations.fire/3`, where an absent
    visitor means no banner applies.

    ## CSP

    Pass `nonce={@csp_nonce}` and it lands on every inline `<script>`.
    """
    use Phoenix.Component

    alias Pixelex.{Consent, Destinations}

    # Which stored credential key holds the id the BROWSER pixel needs. Not
    # always the one the Conversions API uses: Pinterest authenticates server
    # calls with an ad-account id and loads its tag with a different number
    # entirely, and LinkedIn's server API has no use for the partner id its
    # snippet is built around.
    @browser_id_keys %{
      meta: :pixel_id,
      tiktok: :pixel_code,
      snapchat: :pixel_id,
      ga4: :measurement_id,
      reddit: :pixel_id,
      pinterest: :tag_id,
      linkedin: :partner_id
    }

    @safe_id ~r/\A[A-Za-z0-9._-]{1,64}\z/
    @safe_nonce ~r/\A[A-Za-z0-9+\/=_-]{1,128}\z/

    @doc """
    The credential key holding a platform's browser pixel id, or `nil` when the
    platform has no browser pixel pixelex knows how to render.
    """
    @spec id_key(atom()) :: atom() | nil
    def id_key(platform), do: Map.get(@browser_id_keys, platform)

    @doc "Every platform this module can render a snippet for."
    @spec platforms() :: [atom()]
    def platforms, do: Map.keys(@browser_id_keys)

    @doc """
    The browser pixel ids stored for a site, validated.

    Only platforms with a usable id appear. Useful on its own if you would
    rather render the snippets yourself.
    """
    @spec ids(String.t()) :: %{atom() => String.t()}
    def ids(site_id) when is_binary(site_id) do
      credentials = Destinations.credentials(site_id)

      for {platform, key} <- @browser_id_keys,
          value = credentials[platform][key],
          is_binary(value),
          Regex.match?(@safe_id, value),
          into: %{},
          do: {platform, value}
    end

    def ids(_), do: %{}

    attr(:site_id, :string, required: true)

    attr(:consent, :map,
      default: %{},
      doc: "Signals from `Pixelex.Plug.Context`. Empty means no banner applies."
    )

    attr(:nonce, :string, default: nil, doc: "CSP nonce for the inline scripts.")

    @doc """
    Render every browser pixel this site has an id for.

    Each snippet initialises the platform's SDK and sends its page view. Put it
    once in the root layout; it is a no-op for a site with no ids.
    """
    def tags(assigns) do
      ids = if allowed?(assigns.consent), do: ids(assigns.site_id), else: %{}
      assigns = assign(assigns, :markup, markup(ids, assigns.nonce))

      ~H"""
      {Phoenix.HTML.raw(@markup)}
      """
    end

    # Built as one string rather than as HEEx tags, because the engine treats
    # the contents of `<script>` as verbatim text and does not interpolate
    # `{...}` inside it — a template literally cannot put an id in a snippet.
    #
    # Everything interpolated here is either an id that passed `@safe_id` or a
    # nonce that passed `@safe_nonce`. Nothing else reaches the page.
    defp markup(ids, nonce) do
      attrs = nonce_attr(nonce)

      inline =
        [
          {ids[:meta], &meta/1},
          {ids[:tiktok], &tiktok/1},
          {ids[:snapchat], &snapchat/1},
          {ids[:ga4], &ga4/1},
          {ids[:reddit], &reddit/1},
          {ids[:pinterest], &pinterest/1},
          {ids[:linkedin], &linkedin/1}
        ]
        |> Enum.reject(fn {id, _build} -> is_nil(id) end)
        |> Enum.map_join("\n", fn {id, build} -> build.(id) end)

      gtag_src(ids[:ga4], attrs) <> inline_script(inline, attrs)
    end

    # GA4 is the one that needs an external script loaded before its config.
    defp gtag_src(nil, _attrs), do: ""

    defp gtag_src(id, attrs) do
      ~s(<script async#{attrs} src="https://www.googletagmanager.com/gtag/js?id=#{id}"></script>)
    end

    defp inline_script("", _attrs), do: ""
    defp inline_script(inline, attrs), do: "<script#{attrs}>\n#{inline}</script>"

    defp nonce_attr(nonce) when is_binary(nonce) do
      if Regex.match?(@safe_nonce, nonce), do: ~s( nonce="#{nonce}"), else: ""
    end

    defp nonce_attr(_), do: ""

    defp allowed?(consent) when is_map(consent) and map_size(consent) > 0 do
      Consent.destinations_allowed?(consent) == true
    end

    defp allowed?(_), do: true

    # --- the official snippets, with the id interpolated -----------------------
    #
    # Copied from each platform's own installer rather than rewritten. A
    # hand-slimmed loader is the kind of thing that works until the platform
    # changes its SDK and then fails silently for a month.

    defp meta(id) do
      """
      !function(f,b,e,v,n,t,s){if(f.fbq)return;n=f.fbq=function(){n.callMethod?
      n.callMethod.apply(n,arguments):n.queue.push(arguments)};if(!f._fbq)f._fbq=n;
      n.push=n;n.loaded=!0;n.version='2.0';n.queue=[];t=b.createElement(e);t.async=!0;
      t.src=v;s=b.getElementsByTagName(e)[0];s.parentNode.insertBefore(t,s)}(window,
      document,'script','https://connect.facebook.net/en_US/fbevents.js');
      fbq('init','#{id}');fbq('track','PageView');
      """
    end

    defp tiktok(id) do
      """
      !function(w,d,t){w.TiktokAnalyticsObject=t;var ttq=w[t]=w[t]||[];
      ttq.methods=["page","track","identify","instances","debug","on","off","once","ready","alias","group","enableCookie","disableCookie"],
      ttq.setAndDefer=function(t,e){t[e]=function(){t.push([e].concat(Array.prototype.slice.call(arguments,0)))}};
      for(var i=0;i<ttq.methods.length;i++)ttq.setAndDefer(ttq,ttq.methods[i]);
      ttq.instance=function(t){for(var e=ttq._i[t]||[],n=0;n<ttq.methods.length;n++)ttq.setAndDefer(e,ttq.methods[n]);return e},
      ttq.load=function(e,n){var i="https://analytics.tiktok.com/i18n/pixel/events.js";
      ttq._i=ttq._i||{},ttq._i[e]=[],ttq._i[e]._u=i,ttq._t=ttq._t||{},ttq._t[e]=+new Date,ttq._o=ttq._o||{},ttq._o[e]=n||{};
      var o=document.createElement("script");o.type="text/javascript",o.async=!0,o.src=i+"?sdkid="+e+"&lib="+t;
      var a=document.getElementsByTagName("script")[0];a.parentNode.insertBefore(o,a)};
      ttq.load('#{id}');ttq.page();}(window,document,'ttq');
      """
    end

    defp snapchat(id) do
      """
      (function(e,t,n){if(e.snaptr)return;var a=e.snaptr=function(){
      a.handleRequest?a.handleRequest.apply(a,arguments):a.queue.push(arguments)};
      a.queue=[];var s='script';var r=t.createElement(s);r.async=!0;r.src=n;
      var u=t.getElementsByTagName(s)[0];u.parentNode.insertBefore(r,u)})
      (window,document,'https://sc-static.net/scevent.min.js');
      snaptr('init','#{id}');snaptr('track','PAGE_VIEW');
      """
    end

    defp ga4(id) do
      """
      window.dataLayer=window.dataLayer||[];
      function gtag(){dataLayer.push(arguments)}
      gtag('js',new Date());gtag('config','#{id}');
      """
    end

    defp reddit(id) do
      """
      !function(w,d){if(!w.rdt){var p=w.rdt=function(){
      p.sendEvent?p.sendEvent.apply(p,arguments):p.callQueue.push(arguments)};
      p.callQueue=[];var t=d.createElement("script");
      t.src="https://www.redditstatic.com/ads/pixel.js",t.async=!0;
      var s=d.getElementsByTagName("script")[0];s.parentNode.insertBefore(t,s)}}
      (window,document);rdt('init','#{id}');rdt('track','PageVisit');
      """
    end

    defp pinterest(id) do
      """
      !function(e){if(!window.pintrk){window.pintrk=function(){
      window.pintrk.queue.push(Array.prototype.slice.call(arguments))};
      var n=window.pintrk;n.queue=[],n.version="3.0";
      var t=document.createElement("script");t.async=!0,t.src=e;
      var r=document.getElementsByTagName("script")[0];
      r.parentNode.insertBefore(t,r)}}("https://s.pinimg.com/ct/core.js");
      pintrk('load','#{id}');pintrk('page');
      """
    end

    defp linkedin(id) do
      """
      _linkedin_partner_id="#{id}";
      window._linkedin_data_partner_ids=window._linkedin_data_partner_ids||[];
      window._linkedin_data_partner_ids.push(_linkedin_partner_id);
      (function(l){if(!l){window.lintrk=function(a,b){window.lintrk.q.push([a,b])};
      window.lintrk.q=[]}var s=document.getElementsByTagName("script")[0];
      var b=document.createElement("script");b.type="text/javascript";b.async=true;
      b.src="https://snap.licdn.com/li.lms-analytics/insight.min.js";
      s.parentNode.insertBefore(b,s)})(window.lintrk);
      """
    end
  end
end
