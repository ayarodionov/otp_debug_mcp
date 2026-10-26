defmodule BanditShop.Router do
  use Plug.Router

  plug :match
  plug :dispatch

  get "/products/:id" do
    send_resp(conn, 200, ~s({"id": #{id}, "price": #{rem(String.to_integer(id), 50) + 5}}))
  end

  get "/recommendations" do
    send_resp(conn, 200, BanditShop.Recommender.for_visitor())
  end

  match _ do
    send_resp(conn, 404, "not found")
  end
end
