# Tests start real target nodes with :peer and connect to them over
# distribution, so they share OtpDebugMcp.Target and can't run async.
#
# The :old_otp tests need a node running an older OTP release than this
# one, given by OLD_OTP_NODE and OLD_OTP_COOKIE (see old_otp_test.exs), and
# the :new_otp tests one running a newer release, given by NEW_OTP_NODE and
# NEW_OTP_COOKIE (see new_otp_test.exs). The
# :tls_dist tests need the suite to run over TLS (see tls_dist_test.exs).
# The :postgres tests need PostgreSQL's binaries (see PgServer), the :emqx
# ones an EMQX node given by EMQX_NODE (see emqx_test.exs), the :ejabberd
# ones an ejabberd node given by EJABBERD_NODE (see ejabberd_test.exs), the
# :rabbitmq ones a RabbitMQ node given by RABBITMQ_NODE (see
# rabbitmq_test.exs).
tls? = match?({:ok, [[~c"inet_tls" | _] | _]}, :init.get_argument(:proto_dist))

exclude =
  if(System.get_env("OLD_OTP_NODE"), do: [], else: [:old_otp]) ++
    if(System.get_env("NEW_OTP_NODE"), do: [], else: [:new_otp]) ++
    if(tls?, do: [], else: [:tls_dist]) ++
    if(OtpDebugMcp.PgServer.bindir(), do: [], else: [:postgres]) ++
    if(System.get_env("EMQX_NODE"), do: [], else: [:emqx]) ++
    if(System.get_env("EJABBERD_NODE"), do: [], else: [:ejabberd]) ++
    if(System.get_env("RABBITMQ_NODE"), do: [], else: [:rabbitmq])

ExUnit.start(exclude: exclude)
