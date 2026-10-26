defmodule BanditShop.Recommender do
  # Recommendations come from an upstream service that takes 3 seconds to
  # answer; the request handler waits for it, holding its connection.
  def for_visitor do
    upstream_call()
  end

  defp upstream_call do
    Process.sleep(3_000)
    ~s({"recommended": [3, 14, 15]})
  end
end
