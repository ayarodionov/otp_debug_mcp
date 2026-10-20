# Tests start real target nodes with :peer and connect to them over
# distribution, so they share OtpDebugMcp.Target and can't run async.
#
# The :old_otp tests need a node running an older OTP release than this
# one, given by OLD_OTP_NODE and OLD_OTP_COOKIE (see old_otp_test.exs).
exclude = if System.get_env("OLD_OTP_NODE"), do: [], else: [:old_otp]

ExUnit.start(exclude: exclude)
