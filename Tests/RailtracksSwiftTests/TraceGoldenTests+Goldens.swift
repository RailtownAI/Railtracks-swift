//
//  TraceGoldenTests+Goldens.swift
//  RailtracksSwiftTests
//
//  The normalized traces `TraceGoldenTests` compares against, captured from the trace collector as
//  it was before #68. A deliberate change to the trace replaces one with the file the failing test
//  saves.
//

extension RailtracksSwiftTestSuite.TraceGoldenTests {
    static let agentCallingToolsGolden = #"""
{
  "end_time" : "<time>",
  "flow_id" : "128d6f419f238b8ab3f8710a1413e2dc6aca528d15dfd48e4a01309863b3d2be",
  "flow_name" : "Golden Tools",
  "runs" : [
    {
      "edges" : [
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {
              "query" : "alpha"
            },
            "output" : {
              "result" : "Lookup: alpha"
            },
            "status" : "Completed"
          },
          "identifier" : "<id-1>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {
                "query" : "alpha"
              },
              "output" : null,
              "status" : "Open"
            },
            "identifier" : "<id-1>",
            "parent" : null,
            "source" : "<id-2>",
            "stamp" : {
              "identifier" : "Assistant CREATED Lookup",
              "step" : 1,
              "time" : "<time>"
            },
            "target" : "<id-3>"
          },
          "source" : "<id-2>",
          "stamp" : {
            "identifier" : "Finished executing Lookup",
            "step" : 2,
            "time" : "<time>"
          },
          "target" : "<id-3>"
        },
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {
              "query" : "beta"
            },
            "output" : {
              "result" : "Lookup: beta"
            },
            "status" : "Completed"
          },
          "identifier" : "<id-4>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {
                "query" : "beta"
              },
              "output" : null,
              "status" : "Open"
            },
            "identifier" : "<id-4>",
            "parent" : null,
            "source" : "<id-2>",
            "stamp" : {
              "identifier" : "Assistant CREATED Lookup",
              "step" : 3,
              "time" : "<time>"
            },
            "target" : "<id-5>"
          },
          "source" : "<id-2>",
          "stamp" : {
            "identifier" : "Finished executing Lookup",
            "step" : 4,
            "time" : "<time>"
          },
          "target" : "<id-5>"
        },
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {
              "query" : "alpha beta"
            },
            "output" : {
              "result" : "Summarize: alpha beta"
            },
            "status" : "Completed"
          },
          "identifier" : "<id-6>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {
                "query" : "alpha beta"
              },
              "output" : null,
              "status" : "Open"
            },
            "identifier" : "<id-6>",
            "parent" : null,
            "source" : "<id-2>",
            "stamp" : {
              "identifier" : "Assistant CREATED Summarize",
              "step" : 5,
              "time" : "<time>"
            },
            "target" : "<id-7>"
          },
          "source" : "<id-2>",
          "stamp" : {
            "identifier" : "Finished executing Summarize",
            "step" : 6,
            "time" : "<time>"
          },
          "target" : "<id-7>"
        },
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {
              "prompt" : "Find alpha and beta",
              "systemMessage" : "Be brief"
            },
            "output" : "Success",
            "status" : "Completed"
          },
          "identifier" : "<id-8>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {
                "prompt" : "Find alpha and beta",
                "systemMessage" : "Be brief"
              },
              "output" : "Success",
              "status" : "Open"
            },
            "identifier" : "<id-8>",
            "parent" : null,
            "source" : null,
            "stamp" : {
              "identifier" : "START CREATED Assistant",
              "step" : 0,
              "time" : "<time>"
            },
            "target" : "<id-2>"
          },
          "source" : null,
          "stamp" : {
            "identifier" : "Finished executing Assistant",
            "step" : 7,
            "time" : "<time>"
          },
          "target" : "<id-2>"
        }
      ],
      "end_time" : "<time>",
      "name" : "Assistant",
      "nodes" : [
        {
          "details" : {
            "internals" : {
              "latency" : {
                "total_time" : "<duration>"
              }
            }
          },
          "identifier" : "<id-3>",
          "name" : "Lookup",
          "node_type" : "Tool",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-3>",
            "name" : "Lookup",
            "node_type" : "Tool",
            "parent" : null,
            "stamp" : {
              "identifier" : "Assistant CREATED Lookup",
              "step" : 1,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Lookup",
            "step" : 2,
            "time" : "<time>"
          }
        },
        {
          "details" : {
            "internals" : {
              "latency" : {
                "total_time" : "<duration>"
              }
            }
          },
          "identifier" : "<id-5>",
          "name" : "Lookup",
          "node_type" : "Tool",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-5>",
            "name" : "Lookup",
            "node_type" : "Tool",
            "parent" : null,
            "stamp" : {
              "identifier" : "Assistant CREATED Lookup",
              "step" : 3,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Lookup",
            "step" : 4,
            "time" : "<time>"
          }
        },
        {
          "details" : {
            "internals" : {
              "latency" : {
                "total_time" : "<duration>"
              }
            }
          },
          "identifier" : "<id-7>",
          "name" : "Summarize",
          "node_type" : "Tool",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-7>",
            "name" : "Summarize",
            "node_type" : "Tool",
            "parent" : null,
            "stamp" : {
              "identifier" : "Assistant CREATED Summarize",
              "step" : 5,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Summarize",
            "step" : 6,
            "time" : "<time>"
          }
        },
        {
          "details" : {
            "internals" : {
              "guard_details" : [

              ],
              "latency" : {
                "total_time" : "<duration>"
              },
              "llm_details" : [
                {
                  "input" : [
                    {
                      "content" : "Be brief",
                      "role" : "system"
                    },
                    {
                      "content" : "Find alpha and beta",
                      "role" : "user"
                    }
                  ],
                  "input_tokens" : 11,
                  "latency" : 0.5,
                  "model_name" : "apple-on-device",
                  "model_provider" : "AppleAI",
                  "output" : {
                    "content" : [
                      {
                        "arguments" : {
                          "query" : "alpha"
                        },
                        "identifier" : "call_0",
                        "name" : "Lookup"
                      }
                    ],
                    "role" : "assistant"
                  },
                  "output_tokens" : 7
                },
                {
                  "input" : [
                    {
                      "content" : "Be brief",
                      "role" : "system"
                    },
                    {
                      "content" : "Find alpha and beta",
                      "role" : "user"
                    },
                    {
                      "content" : [
                        {
                          "arguments" : {
                            "query" : "alpha"
                          },
                          "identifier" : "call_0",
                          "name" : "Lookup"
                        }
                      ],
                      "role" : "assistant"
                    },
                    {
                      "content" : {
                        "identifier" : "call_0",
                        "name" : "Lookup",
                        "result" : "Lookup: alpha"
                      },
                      "role" : "tool"
                    }
                  ],
                  "input_tokens" : 11,
                  "latency" : 0.5,
                  "model_name" : "apple-on-device",
                  "model_provider" : "AppleAI",
                  "output" : {
                    "content" : [
                      {
                        "arguments" : {
                          "query" : "beta"
                        },
                        "identifier" : "call_1",
                        "name" : "Lookup"
                      }
                    ],
                    "role" : "assistant"
                  },
                  "output_tokens" : 7
                },
                {
                  "input" : [
                    {
                      "content" : "Be brief",
                      "role" : "system"
                    },
                    {
                      "content" : "Find alpha and beta",
                      "role" : "user"
                    },
                    {
                      "content" : [
                        {
                          "arguments" : {
                            "query" : "alpha"
                          },
                          "identifier" : "call_0",
                          "name" : "Lookup"
                        }
                      ],
                      "role" : "assistant"
                    },
                    {
                      "content" : {
                        "identifier" : "call_0",
                        "name" : "Lookup",
                        "result" : "Lookup: alpha"
                      },
                      "role" : "tool"
                    },
                    {
                      "content" : [
                        {
                          "arguments" : {
                            "query" : "beta"
                          },
                          "identifier" : "call_1",
                          "name" : "Lookup"
                        }
                      ],
                      "role" : "assistant"
                    },
                    {
                      "content" : {
                        "identifier" : "call_1",
                        "name" : "Lookup",
                        "result" : "Lookup: beta"
                      },
                      "role" : "tool"
                    }
                  ],
                  "input_tokens" : 11,
                  "latency" : 0.5,
                  "model_name" : "apple-on-device",
                  "model_provider" : "AppleAI",
                  "output" : {
                    "content" : [
                      {
                        "arguments" : {
                          "query" : "alpha beta"
                        },
                        "identifier" : "call_2",
                        "name" : "Summarize"
                      }
                    ],
                    "role" : "assistant"
                  },
                  "output_tokens" : 7
                },
                {
                  "input" : [
                    {
                      "content" : "Be brief",
                      "role" : "system"
                    },
                    {
                      "content" : "Find alpha and beta",
                      "role" : "user"
                    },
                    {
                      "content" : [
                        {
                          "arguments" : {
                            "query" : "alpha"
                          },
                          "identifier" : "call_0",
                          "name" : "Lookup"
                        }
                      ],
                      "role" : "assistant"
                    },
                    {
                      "content" : {
                        "identifier" : "call_0",
                        "name" : "Lookup",
                        "result" : "Lookup: alpha"
                      },
                      "role" : "tool"
                    },
                    {
                      "content" : [
                        {
                          "arguments" : {
                            "query" : "beta"
                          },
                          "identifier" : "call_1",
                          "name" : "Lookup"
                        }
                      ],
                      "role" : "assistant"
                    },
                    {
                      "content" : {
                        "identifier" : "call_1",
                        "name" : "Lookup",
                        "result" : "Lookup: beta"
                      },
                      "role" : "tool"
                    },
                    {
                      "content" : [
                        {
                          "arguments" : {
                            "query" : "alpha beta"
                          },
                          "identifier" : "call_2",
                          "name" : "Summarize"
                        }
                      ],
                      "role" : "assistant"
                    },
                    {
                      "content" : {
                        "identifier" : "call_2",
                        "name" : "Summarize",
                        "result" : "Summarize: alpha beta"
                      },
                      "role" : "tool"
                    }
                  ],
                  "input_tokens" : 11,
                  "latency" : 0.5,
                  "model_name" : "apple-on-device",
                  "model_provider" : "AppleAI",
                  "output" : {
                    "content" : "alpha and beta",
                    "role" : "assistant"
                  },
                  "output_tokens" : 7
                }
              ]
            }
          },
          "identifier" : "<id-2>",
          "name" : "Assistant",
          "node_type" : "Agent",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-2>",
            "name" : "Assistant",
            "node_type" : "Agent",
            "parent" : null,
            "stamp" : {
              "identifier" : "START CREATED Assistant",
              "step" : 0,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Assistant",
            "step" : 7,
            "time" : "<time>"
          }
        }
      ],
      "run_id" : "<id-8>",
      "start_time" : "<time>",
      "status" : "Completed",
      "steps" : [
        {
          "identifier" : "START CREATED Assistant",
          "step" : 0,
          "time" : "<time>"
        },
        {
          "identifier" : "Assistant CREATED Lookup",
          "step" : 1,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Lookup",
          "step" : 2,
          "time" : "<time>"
        },
        {
          "identifier" : "Assistant CREATED Lookup",
          "step" : 3,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Lookup",
          "step" : 4,
          "time" : "<time>"
        },
        {
          "identifier" : "Assistant CREATED Summarize",
          "step" : 5,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Summarize",
          "step" : 6,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Assistant",
          "step" : 7,
          "time" : "<time>"
        }
      ]
    }
  ],
  "session_id" : "<id-9>",
  "session_name" : null,
  "start_time" : "<time>"
}
"""#

    static let guardrailsGolden = #"""
{
  "end_time" : "<time>",
  "flow_id" : "c92576236c6fc05deddfe26863890b7582b42edd4b44880b6816ffdc75d5aeb3",
  "flow_name" : "Golden Guardrails",
  "runs" : [
    {
      "edges" : [
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {
              "prompt" : "my number is [redacted]"
            },
            "output" : "Success",
            "status" : "Completed"
          },
          "identifier" : "<id-1>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {
                "prompt" : "my number is [redacted]"
              },
              "output" : "Success",
              "status" : "Open"
            },
            "identifier" : "<id-1>",
            "parent" : null,
            "source" : null,
            "stamp" : {
              "identifier" : "START CREATED Guarded",
              "step" : 0,
              "time" : "<time>"
            },
            "target" : "<id-2>"
          },
          "source" : null,
          "stamp" : {
            "identifier" : "Finished executing Guarded",
            "step" : 1,
            "time" : "<time>"
          },
          "target" : "<id-2>"
        }
      ],
      "end_time" : "<time>",
      "name" : "Guarded",
      "nodes" : [
        {
          "details" : {
            "internals" : {
              "guard_details" : [
                {
                  "action" : "transform",
                  "meta" : {
                    "count" : 1
                  },
                  "phase" : "llm_input",
                  "rail_name" : "Redact",
                  "reason" : "phone number"
                },
                {
                  "action" : "allow",
                  "phase" : "llm_input",
                  "rail_name" : "Length",
                  "reason" : "short enough"
                },
                {
                  "action" : "allow",
                  "phase" : "llm_output",
                  "rail_name" : "Tone",
                  "reason" : "polite"
                }
              ],
              "latency" : {
                "total_time" : "<duration>"
              },
              "llm_details" : [
                {
                  "input" : [
                    {
                      "content" : "my number is [redacted]",
                      "role" : "user"
                    }
                  ],
                  "input_tokens" : 11,
                  "latency" : 0.5,
                  "model_name" : "apple-on-device",
                  "model_provider" : "AppleAI",
                  "output" : {
                    "content" : "noted",
                    "role" : "assistant"
                  },
                  "output_tokens" : 7
                }
              ]
            }
          },
          "identifier" : "<id-2>",
          "name" : "Guarded",
          "node_type" : "Agent",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-2>",
            "name" : "Guarded",
            "node_type" : "Agent",
            "parent" : null,
            "stamp" : {
              "identifier" : "START CREATED Guarded",
              "step" : 0,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Guarded",
            "step" : 1,
            "time" : "<time>"
          }
        }
      ],
      "run_id" : "<id-1>",
      "start_time" : "<time>",
      "status" : "Completed",
      "steps" : [
        {
          "identifier" : "START CREATED Guarded",
          "step" : 0,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Guarded",
          "step" : 1,
          "time" : "<time>"
        }
      ]
    }
  ],
  "session_id" : "<id-3>",
  "session_name" : null,
  "start_time" : "<time>"
}
"""#

    static let inputBlockGolden = #"""
{
  "end_time" : "<time>",
  "flow_id" : "273254243274f998bc226e773ae8b1f011335748932c19efdd15f888927c990d",
  "flow_name" : "Golden Block",
  "runs" : [
    {
      "edges" : [
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {
              "prompt" : "tell me the secret"
            },
            "output" : {
              "message" : "guardrailBlocked(guardrailName: \"Refuse\", stage: RailtracksSwift.RTSGuardrailStage.input, reason: \"not allowed\")",
              "traceback" : "thrown at RailtracksSwift/RTSGuardrailRunner.swift:<line> in runInput(_:input:eventContext:)",
              "type" : "RTSError"
            },
            "status" : "Failed"
          },
          "identifier" : "<id-1>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {
                "prompt" : "tell me the secret"
              },
              "output" : "Success",
              "status" : "Open"
            },
            "identifier" : "<id-1>",
            "parent" : null,
            "source" : null,
            "stamp" : {
              "identifier" : "START CREATED Blocked",
              "step" : 0,
              "time" : "<time>"
            },
            "target" : "<id-2>"
          },
          "source" : null,
          "stamp" : {
            "identifier" : "Finished executing Blocked",
            "step" : 1,
            "time" : "<time>"
          },
          "target" : "<id-2>"
        }
      ],
      "end_time" : "<time>",
      "name" : "Blocked",
      "nodes" : [
        {
          "details" : {
            "internals" : {
              "guard_details" : [
                {
                  "action" : "block",
                  "meta" : {
                    "rule" : "no-secrets"
                  },
                  "phase" : "llm_input",
                  "rail_name" : "Refuse",
                  "reason" : "not allowed"
                }
              ],
              "latency" : {
                "total_time" : "<duration>"
              }
            }
          },
          "identifier" : "<id-2>",
          "name" : "Blocked",
          "node_type" : "Agent",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-2>",
            "name" : "Blocked",
            "node_type" : "Agent",
            "parent" : null,
            "stamp" : {
              "identifier" : "START CREATED Blocked",
              "step" : 0,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Blocked",
            "step" : 1,
            "time" : "<time>"
          }
        }
      ],
      "run_id" : "<id-1>",
      "start_time" : "<time>",
      "status" : "Failed",
      "steps" : [
        {
          "identifier" : "START CREATED Blocked",
          "step" : 0,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Blocked",
          "step" : 1,
          "time" : "<time>"
        }
      ]
    }
  ],
  "session_id" : "<id-3>",
  "session_name" : null,
  "start_time" : "<time>"
}
"""#

    static let orchestratorRootGolden = #"""
{
  "end_time" : "<time>",
  "flow_id" : "1c92c5b52be8b9fedd497cd4d88175b4cb79c44f2c38effdf78b1bfa9dbf03bf",
  "flow_name" : "Golden Orchestrator",
  "runs" : [
    {
      "edges" : [
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {
              "query" : "trains"
            },
            "output" : {
              "result" : "Lookup: trains"
            },
            "status" : "Completed"
          },
          "identifier" : "<id-1>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {
                "query" : "trains"
              },
              "output" : null,
              "status" : "Open"
            },
            "identifier" : "<id-1>",
            "parent" : null,
            "source" : "<id-2>",
            "stamp" : {
              "identifier" : "Researcher CREATED Lookup",
              "step" : 2,
              "time" : "<time>"
            },
            "target" : "<id-3>"
          },
          "source" : "<id-2>",
          "stamp" : {
            "identifier" : "Finished executing Lookup",
            "step" : 3,
            "time" : "<time>"
          },
          "target" : "<id-3>"
        },
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {
              "prompt" : "Research trains"
            },
            "output" : "Success",
            "status" : "Completed"
          },
          "identifier" : "<id-4>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {
                "prompt" : "Research trains"
              },
              "output" : "Success",
              "status" : "Open"
            },
            "identifier" : "<id-4>",
            "parent" : null,
            "source" : "<id-5>",
            "stamp" : {
              "identifier" : "Planner CREATED Researcher",
              "step" : 1,
              "time" : "<time>"
            },
            "target" : "<id-2>"
          },
          "source" : "<id-5>",
          "stamp" : {
            "identifier" : "Finished executing Researcher",
            "step" : 4,
            "time" : "<time>"
          },
          "target" : "<id-2>"
        },
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {
              "draft" : "trains run on rails"
            },
            "output" : {
              "text" : "formatted: trains run on rails"
            },
            "status" : "Completed"
          },
          "identifier" : "<id-6>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {
                "draft" : "trains run on rails"
              },
              "output" : null,
              "status" : "Open"
            },
            "identifier" : "<id-6>",
            "parent" : null,
            "source" : "<id-5>",
            "stamp" : {
              "identifier" : "Planner CREATED Formatter",
              "step" : 5,
              "time" : "<time>"
            },
            "target" : "<id-7>"
          },
          "source" : "<id-5>",
          "stamp" : {
            "identifier" : "Finished executing Formatter",
            "step" : 6,
            "time" : "<time>"
          },
          "target" : "<id-7>"
        },
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {
              "topic" : "trains"
            },
            "output" : {
              "summary" : "formatted: trains run on rails"
            },
            "status" : "Completed"
          },
          "identifier" : "<id-8>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {
                "topic" : "trains"
              },
              "output" : null,
              "status" : "Open"
            },
            "identifier" : "<id-8>",
            "parent" : null,
            "source" : null,
            "stamp" : {
              "identifier" : "START CREATED Planner",
              "step" : 0,
              "time" : "<time>"
            },
            "target" : "<id-5>"
          },
          "source" : null,
          "stamp" : {
            "identifier" : "Finished executing Planner",
            "step" : 7,
            "time" : "<time>"
          },
          "target" : "<id-5>"
        }
      ],
      "end_time" : "<time>",
      "name" : "Planner",
      "nodes" : [
        {
          "details" : {
            "internals" : {
              "latency" : {
                "total_time" : "<duration>"
              }
            }
          },
          "identifier" : "<id-3>",
          "name" : "Lookup",
          "node_type" : "Tool",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-3>",
            "name" : "Lookup",
            "node_type" : "Tool",
            "parent" : null,
            "stamp" : {
              "identifier" : "Researcher CREATED Lookup",
              "step" : 2,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Lookup",
            "step" : 3,
            "time" : "<time>"
          }
        },
        {
          "details" : {
            "internals" : {
              "guard_details" : [

              ],
              "latency" : {
                "total_time" : "<duration>"
              },
              "llm_details" : [
                {
                  "input" : [
                    {
                      "content" : "Research trains",
                      "role" : "user"
                    }
                  ],
                  "input_tokens" : 11,
                  "latency" : 0.5,
                  "model_name" : "not-a-priced-model",
                  "model_provider" : "Gemini",
                  "output" : {
                    "content" : [
                      {
                        "arguments" : {
                          "query" : "trains"
                        },
                        "identifier" : "call_0",
                        "name" : "Lookup"
                      }
                    ],
                    "role" : "assistant"
                  },
                  "output_tokens" : 7
                },
                {
                  "input" : [
                    {
                      "content" : "Research trains",
                      "role" : "user"
                    },
                    {
                      "content" : [
                        {
                          "arguments" : {
                            "query" : "trains"
                          },
                          "identifier" : "call_0",
                          "name" : "Lookup"
                        }
                      ],
                      "role" : "assistant"
                    },
                    {
                      "content" : {
                        "identifier" : "call_0",
                        "name" : "Lookup",
                        "result" : "Lookup: trains"
                      },
                      "role" : "tool"
                    }
                  ],
                  "input_tokens" : 11,
                  "latency" : 0.5,
                  "model_name" : "not-a-priced-model",
                  "model_provider" : "Gemini",
                  "output" : {
                    "content" : "trains run on rails",
                    "role" : "assistant"
                  },
                  "output_tokens" : 7
                }
              ]
            }
          },
          "identifier" : "<id-2>",
          "name" : "Researcher",
          "node_type" : "Agent",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-2>",
            "name" : "Researcher",
            "node_type" : "Agent",
            "parent" : null,
            "stamp" : {
              "identifier" : "Planner CREATED Researcher",
              "step" : 1,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Researcher",
            "step" : 4,
            "time" : "<time>"
          }
        },
        {
          "details" : {
            "internals" : {
              "latency" : {
                "total_time" : "<duration>"
              }
            }
          },
          "identifier" : "<id-7>",
          "name" : "Formatter",
          "node_type" : "Tool",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-7>",
            "name" : "Formatter",
            "node_type" : "Tool",
            "parent" : null,
            "stamp" : {
              "identifier" : "Planner CREATED Formatter",
              "step" : 5,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Formatter",
            "step" : 6,
            "time" : "<time>"
          }
        },
        {
          "details" : {
            "internals" : {
              "latency" : {
                "total_time" : "<duration>"
              }
            }
          },
          "identifier" : "<id-5>",
          "name" : "Planner",
          "node_type" : "Tool",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-5>",
            "name" : "Planner",
            "node_type" : "Tool",
            "parent" : null,
            "stamp" : {
              "identifier" : "START CREATED Planner",
              "step" : 0,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Planner",
            "step" : 7,
            "time" : "<time>"
          }
        }
      ],
      "run_id" : "<id-8>",
      "start_time" : "<time>",
      "status" : "Completed",
      "steps" : [
        {
          "identifier" : "START CREATED Planner",
          "step" : 0,
          "time" : "<time>"
        },
        {
          "identifier" : "Planner CREATED Researcher",
          "step" : 1,
          "time" : "<time>"
        },
        {
          "identifier" : "Researcher CREATED Lookup",
          "step" : 2,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Lookup",
          "step" : 3,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Researcher",
          "step" : 4,
          "time" : "<time>"
        },
        {
          "identifier" : "Planner CREATED Formatter",
          "step" : 5,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Formatter",
          "step" : 6,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Planner",
          "step" : 7,
          "time" : "<time>"
        }
      ]
    }
  ],
  "session_id" : "<id-9>",
  "session_name" : null,
  "start_time" : "<time>"
}
"""#

    static let endOnErrorStopGolden = #"""
{
  "end_time" : "<time>",
  "flow_id" : "ff6ccb17eb5190def55710451828194fee5ecf6df09eb073d5570fbccd5f19db",
  "flow_name" : "Golden End On Error",
  "runs" : [
    {
      "edges" : [
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {
              "query" : "1 / 0"
            },
            "output" : {
              "message" : "DivisionByZero()",
              "traceback" : null,
              "type" : "DivisionByZero"
            },
            "status" : "Failed"
          },
          "identifier" : "<id-1>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {
                "query" : "1 / 0"
              },
              "output" : null,
              "status" : "Open"
            },
            "identifier" : "<id-1>",
            "parent" : null,
            "source" : "<id-2>",
            "stamp" : {
              "identifier" : "Calculator CREATED Divide",
              "step" : 2,
              "time" : "<time>"
            },
            "target" : "<id-3>"
          },
          "source" : "<id-2>",
          "stamp" : {
            "identifier" : "Finished executing Divide",
            "step" : 3,
            "time" : "<time>"
          },
          "target" : "<id-3>"
        },
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {
              "prompt" : "What is 1 / 0?"
            },
            "output" : {
              "message" : "runTerminated(reason: endOnError(nodeName: \"Divide\", underlying: DivisionByZero()))",
              "traceback" : "thrown at RailtracksSwift/RTSNodeInvoker.swift:<line> in invokeCore(_:nodeType:provider:model:input:createdBy:runInputGuardrails:runOutputGuardrails:emitLLMEvents:execute:)",
              "type" : "RTSError"
            },
            "status" : "Failed"
          },
          "identifier" : "<id-4>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {
                "prompt" : "What is 1 / 0?"
              },
              "output" : "Success",
              "status" : "Open"
            },
            "identifier" : "<id-4>",
            "parent" : null,
            "source" : "<id-5>",
            "stamp" : {
              "identifier" : "Pipeline CREATED Calculator",
              "step" : 1,
              "time" : "<time>"
            },
            "target" : "<id-2>"
          },
          "source" : "<id-5>",
          "stamp" : {
            "identifier" : "Finished executing Calculator",
            "step" : 4,
            "time" : "<time>"
          },
          "target" : "<id-2>"
        },
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {

            },
            "output" : {
              "message" : "runTerminated(reason: endOnError(nodeName: \"Divide\", underlying: DivisionByZero()))",
              "traceback" : "thrown at RailtracksSwift/RTSNodeInvoker.swift:<line> in invokeCore(_:nodeType:provider:model:input:createdBy:runInputGuardrails:runOutputGuardrails:emitLLMEvents:execute:)",
              "type" : "RTSError"
            },
            "status" : "Failed"
          },
          "identifier" : "<id-6>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {

              },
              "output" : null,
              "status" : "Open"
            },
            "identifier" : "<id-6>",
            "parent" : null,
            "source" : null,
            "stamp" : {
              "identifier" : "START CREATED Pipeline",
              "step" : 0,
              "time" : "<time>"
            },
            "target" : "<id-5>"
          },
          "source" : null,
          "stamp" : {
            "identifier" : "Finished executing Pipeline",
            "step" : 5,
            "time" : "<time>"
          },
          "target" : "<id-5>"
        }
      ],
      "end_time" : "<time>",
      "name" : "Pipeline",
      "nodes" : [
        {
          "details" : {
            "internals" : {
              "latency" : {
                "total_time" : "<duration>"
              }
            }
          },
          "identifier" : "<id-3>",
          "name" : "Divide",
          "node_type" : "Tool",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-3>",
            "name" : "Divide",
            "node_type" : "Tool",
            "parent" : null,
            "stamp" : {
              "identifier" : "Calculator CREATED Divide",
              "step" : 2,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Divide",
            "step" : 3,
            "time" : "<time>"
          }
        },
        {
          "details" : {
            "internals" : {
              "guard_details" : [

              ],
              "latency" : {
                "total_time" : "<duration>"
              },
              "llm_details" : [
                {
                  "input" : [
                    {
                      "content" : "What is 1 / 0?",
                      "role" : "user"
                    }
                  ],
                  "input_tokens" : 11,
                  "latency" : 0.5,
                  "model_name" : "apple-on-device",
                  "model_provider" : "AppleAI",
                  "output" : {
                    "content" : [
                      {
                        "arguments" : {
                          "query" : "1 / 0"
                        },
                        "identifier" : "call_0",
                        "name" : "Divide"
                      }
                    ],
                    "role" : "assistant"
                  },
                  "output_tokens" : 7
                }
              ]
            }
          },
          "identifier" : "<id-2>",
          "name" : "Calculator",
          "node_type" : "Agent",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-2>",
            "name" : "Calculator",
            "node_type" : "Agent",
            "parent" : null,
            "stamp" : {
              "identifier" : "Pipeline CREATED Calculator",
              "step" : 1,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Calculator",
            "step" : 4,
            "time" : "<time>"
          }
        },
        {
          "details" : {
            "internals" : {
              "latency" : {
                "total_time" : "<duration>"
              }
            }
          },
          "identifier" : "<id-5>",
          "name" : "Pipeline",
          "node_type" : "Tool",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-5>",
            "name" : "Pipeline",
            "node_type" : "Tool",
            "parent" : null,
            "stamp" : {
              "identifier" : "START CREATED Pipeline",
              "step" : 0,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Pipeline",
            "step" : 5,
            "time" : "<time>"
          }
        }
      ],
      "run_id" : "<id-6>",
      "start_time" : "<time>",
      "status" : "Failed",
      "steps" : [
        {
          "identifier" : "START CREATED Pipeline",
          "step" : 0,
          "time" : "<time>"
        },
        {
          "identifier" : "Pipeline CREATED Calculator",
          "step" : 1,
          "time" : "<time>"
        },
        {
          "identifier" : "Calculator CREATED Divide",
          "step" : 2,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Divide",
          "step" : 3,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Calculator",
          "step" : 4,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Pipeline",
          "step" : 5,
          "time" : "<time>"
        }
      ]
    }
  ],
  "session_id" : "<id-7>",
  "session_name" : null,
  "start_time" : "<time>"
}
"""#

    static let twoRunsGolden = #"""
{
  "end_time" : "<time>",
  "flow_id" : "b10f40a9a84299bb261675bf6e5b8cf927adab98939d249cf03e589c42377a82",
  "flow_name" : "Golden Two Runs",
  "runs" : [
    {
      "edges" : [
        {
          "details" : {
            "input_args" : [

            ],
            "input_kwargs" : {
              "prompt" : "once more"
            },
            "output" : "Success",
            "status" : "Completed"
          },
          "identifier" : "<id-1>",
          "parent" : {
            "details" : {
              "input_args" : [

              ],
              "input_kwargs" : {
                "prompt" : "once more"
              },
              "output" : "Success",
              "status" : "Open"
            },
            "identifier" : "<id-1>",
            "parent" : null,
            "source" : null,
            "stamp" : {
              "identifier" : "START CREATED Repeater",
              "step" : 0,
              "time" : "<time>"
            },
            "target" : "<id-2>"
          },
          "source" : null,
          "stamp" : {
            "identifier" : "Finished executing Repeater",
            "step" : 1,
            "time" : "<time>"
          },
          "target" : "<id-2>"
        }
      ],
      "end_time" : "<time>",
      "name" : "Repeater",
      "nodes" : [
        {
          "details" : {
            "internals" : {
              "guard_details" : [
                {
                  "action" : "allow",
                  "phase" : "llm_input",
                  "rail_name" : "PromptCheck",
                  "reason" : "fine"
                }
              ],
              "latency" : {
                "total_time" : "<duration>"
              },
              "llm_details" : [
                {
                  "input" : [
                    {
                      "content" : "once more",
                      "role" : "user"
                    }
                  ],
                  "input_tokens" : 11,
                  "latency" : 0.5,
                  "model_name" : "apple-on-device",
                  "model_provider" : "AppleAI",
                  "output" : {
                    "content" : "again",
                    "role" : "assistant"
                  },
                  "output_tokens" : 7
                }
              ]
            }
          },
          "identifier" : "<id-2>",
          "name" : "Repeater",
          "node_type" : "Agent",
          "parent" : {
            "details" : {
              "internals" : {

              }
            },
            "identifier" : "<id-2>",
            "name" : "Repeater",
            "node_type" : "Agent",
            "parent" : null,
            "stamp" : {
              "identifier" : "START CREATED Repeater",
              "step" : 0,
              "time" : "<time>"
            }
          },
          "stamp" : {
            "identifier" : "Finished executing Repeater",
            "step" : 1,
            "time" : "<time>"
          }
        }
      ],
      "run_id" : "<id-1>",
      "start_time" : "<time>",
      "status" : "Completed",
      "steps" : [
        {
          "identifier" : "START CREATED Repeater",
          "step" : 0,
          "time" : "<time>"
        },
        {
          "identifier" : "Finished executing Repeater",
          "step" : 1,
          "time" : "<time>"
        }
      ]
    }
  ],
  "session_id" : "<id-3>",
  "session_name" : null,
  "start_time" : "<time>"
}
"""#
}

extension RailtracksSwiftTestSuite.TraceGoldenTests {
    /// Captured from the collector before #68 and confirmed identical after it.
    static let signpostsGolden = #"""
graph Lookup node=<node:Lookup> parent=Researcher parentID=<node:Researcher> type=Tool parentType=Agent error=false parentError=false cost=0.0 model= session=<session> run=<run> start=<time>
graph Planner node=<node:Planner> parent= parentID= type=Function parentType=nil error=false parentError=false cost=0.0 model= session=<session> run=<run> start=<time>
graph Researcher node=<node:Researcher> parent=Planner parentID=<node:Planner> type=Agent parentType=Function error=false parentError=false cost=0.0 model= session=<session> run=<run> start=<time>
io Lookup 001 kwarg:query node=<node:Lookup> message=<id>-kwarg-query source=edge direction=Input role=kwarg:query model= provider= cost=0.0 latency=0.0 tokens=0/0 content=trains guards=false/false session=<session> run=<run> start=<time>
io Lookup 002 result node=<node:Lookup> message=<id>-out2 source=edge direction=Output role=result model= provider= cost=0.0 latency=0.0 tokens=0/0 content=Lookup: trains guards=false/false session=<session> run=<run> start=<time>
io Planner 009 kwarg:topic node=<node:Planner> message=<run>-kwarg-topic source=edge direction=Input role=kwarg:topic model= provider= cost=0.0 latency=0.0 tokens=0/0 content=trains guards=false/false session=<session> run=<run> start=<time>
io Planner 010 summary node=<node:Planner> message=<run>-out10 source=edge direction=Output role=summary model= provider= cost=0.0 latency=0.0 tokens=0/0 content=trains run on rails guards=false/false session=<session> run=<run> start=<time>
io Researcher 003 kwarg:prompt node=<node:Researcher> message=<id>-kwarg-prompt source=edge direction=Input role=kwarg:prompt model=on-device provider=AppleAI cost=0.0 latency=0.0 tokens=0/0 content=Research trains guards=true/false session=<session> run=<run> start=<time>
io Researcher 004 result node=<node:Researcher> message=<id>-out4 source=edge direction=Output role=result model=on-device provider=AppleAI cost=0.0 latency=0.0 tokens=0/0 content=Success guards=true/false session=<session> run=<run> start=<time>
io Researcher 005 user node=<node:Researcher> message=<id> source=llm direction=Input role=user model=apple-on-device provider=AppleAI cost=0.0 latency=0.0 tokens=0/0 content=Research trains guards=true/false session=<session> run=<run> start=<time>
io Researcher 006 assistant node=<node:Researcher> message=<id> source=llm direction=Output role=assistant model=apple-on-device provider=AppleAI cost=0.0 latency=0.5 tokens=11/7 content= guards=true/false session=<session> run=<run> start=<time>
io Researcher 007 tool node=<node:Researcher> message=<id> source=llm direction=Output role=tool model=apple-on-device provider=AppleAI cost=0.0 latency=0.0 tokens=0/0 content=Lookup: trains guards=true/false session=<session> run=<run> start=<time>
io Researcher 008 assistant node=<node:Researcher> message=<id> source=llm direction=Output role=assistant model=apple-on-device provider=AppleAI cost=0.0 latency=0.5 tokens=11/7 content=trains run on rails guards=true/false session=<session> run=<run> start=<time>
tree Lookup node=<node:Lookup> type=Tool model= provider= cost=0.0 latency=<duration> tokens=0/0 error=false ancestors=Planner>Researcher guards=false/false session=<session> run=<run> start=<time>
tree Planner node=<node:Planner> type=Function model= provider= cost=0.0 latency=<duration> tokens=0/0 error=false ancestors= guards=false/false session=<session> run=<run> start=<time>
tree Researcher node=<node:Researcher> type=Agent model=apple-on-device provider=AppleAI cost=0.0 latency=<duration> tokens=22/14 error=false ancestors=Planner guards=true/false session=<session> run=<run> start=<time>
"""#
}

// MARK: - Interval signposts

extension RailtracksSwiftTestSuite.TraceGoldenTests {
    /// Captured from `invokeCore`'s calls before #70.
    static let agentCallingToolsIntervals = #"""
begin Assistant node=<node:Assistant> parent=none parentName= type=Agent session=<session> run=<run:Assistant> guards=false/false instructions=Be brief input={prompt: Find alpha and beta, systemMessage: Be brief}
begin Lookup node=<node:Lookup> parent=<node:Assistant> parentName=Assistant type=Tool session=<session> run=<run:Lookup> guards=false/false instructions=nil input={query: alpha}
end Lookup node=<node:Lookup> parentName=Assistant type=Tool session=<session> run=<run:Lookup> output={result: Lookup: alpha} error=nil
begin Lookup node=<node:Lookup-2> parent=<node:Assistant> parentName=Assistant type=Tool session=<session> run=<run:Lookup-2> guards=false/false instructions=nil input={query: beta}
end Lookup node=<node:Lookup-2> parentName=Assistant type=Tool session=<session> run=<run:Lookup-2> output={result: Lookup: beta} error=nil
begin Summarize node=<node:Summarize> parent=<node:Assistant> parentName=Assistant type=Tool session=<session> run=<run:Summarize> guards=false/false instructions=nil input={query: alpha beta}
end Summarize node=<node:Summarize> parentName=Assistant type=Tool session=<session> run=<run:Summarize> output={result: Summarize: alpha beta} error=nil
end Assistant node=<node:Assistant> parentName= type=Agent session=<session> run=<run:Assistant> output={result: alpha and beta} error=nil
"""#

    /// The begin carries the input after the transform.
    static let guardrailsIntervals = #"""
begin Guarded node=<node:Guarded> parent=none parentName= type=Agent session=<session> run=<run:Guarded> guards=true/true instructions=nil input={prompt: my number is [redacted]}
end Guarded node=<node:Guarded> parentName= type=Agent session=<session> run=<run:Guarded> output={result: noted} error=nil
"""#

    /// A blocked node still begins, where its body would have run.
    static let inputBlockIntervals = #"""
begin Blocked node=<node:Blocked> parent=none parentName= type=Agent session=<session> run=<run:Blocked> guards=true/false instructions=nil input={prompt: tell me the secret}
end Blocked node=<node:Blocked> parentName= type=Agent session=<session> run=<run:Blocked> output=nil error=guardrailBlocked(guardrailName: "Refuse", stage: RailtracksSwift.RTSGuardrailStage.input, reason: "not allowed")
"""#

    static let orchestratorRootIntervals = #"""
begin Planner node=<node:Planner> parent=none parentName= type=Function session=<session> run=<run:Planner> guards=false/false instructions=nil input={topic: trains}
begin Researcher node=<node:Researcher> parent=<node:Planner> parentName=Planner type=Agent session=<session> run=<run:Researcher> guards=false/false instructions=nil input={prompt: Research trains}
begin Lookup node=<node:Lookup> parent=<node:Researcher> parentName=Researcher type=Tool session=<session> run=<run:Lookup> guards=false/false instructions=nil input={query: trains}
end Lookup node=<node:Lookup> parentName=Researcher type=Tool session=<session> run=<run:Lookup> output={result: Lookup: trains} error=nil
end Researcher node=<node:Researcher> parentName=Planner type=Agent session=<session> run=<run:Researcher> output={result: trains run on rails} error=nil
begin Formatter node=<node:Formatter> parent=<node:Planner> parentName=Planner type=Function session=<session> run=<run:Formatter> guards=false/false instructions=nil input={draft: trains run on rails}
end Formatter node=<node:Formatter> parentName=Planner type=Function session=<session> run=<run:Formatter> output={text: formatted: trains run on rails} error=nil
end Planner node=<node:Planner> parentName= type=Function session=<session> run=<run:Planner> output={summary: formatted: trains run on rails} error=nil
"""#

    /// The failing node keeps its own error. The nodes the stop cut short end with it.
    static let endOnErrorStopIntervals = #"""
begin Pipeline node=<node:Pipeline> parent=none parentName= type=Function session=<session> run=<run:Pipeline> guards=false/false instructions=nil input={}
begin Calculator node=<node:Calculator> parent=<node:Pipeline> parentName=Pipeline type=Agent session=<session> run=<run:Calculator> guards=false/false instructions=nil input={prompt: What is 1 / 0?}
begin Divide node=<node:Divide> parent=<node:Calculator> parentName=Calculator type=Tool session=<session> run=<run:Divide> guards=false/false instructions=nil input={query: 1 / 0}
end Divide node=<node:Divide> parentName=Calculator type=Tool session=<session> run=<run:Divide> output=nil error=DivisionByZero()
end Calculator node=<node:Calculator> parentName=Pipeline type=Agent session=<session> run=<run:Calculator> output=nil error=runTerminated(reason: endOnError(nodeName: "Divide", underlying: DivisionByZero()))
end Pipeline node=<node:Pipeline> parentName= type=Function session=<session> run=<run:Pipeline> output=nil error=runTerminated(reason: endOnError(nodeName: "Divide", underlying: DivisionByZero()))
"""#

    /// Cleanup is invoked after the stop: it begins and ends with the stop, and its body never runs.
    static let nodeAfterStopIntervals = #"""
begin Pipeline node=<node:Pipeline> parent=none parentName= type=Function session=<session> run=<run:Pipeline> guards=false/false instructions=nil input={}
begin Calculator node=<node:Calculator> parent=<node:Pipeline> parentName=Pipeline type=Agent session=<session> run=<run:Calculator> guards=false/false instructions=nil input={prompt: What is 1 / 0?}
begin Divide node=<node:Divide> parent=<node:Calculator> parentName=Calculator type=Tool session=<session> run=<run:Divide> guards=false/false instructions=nil input={query: 1 / 0}
end Divide node=<node:Divide> parentName=Calculator type=Tool session=<session> run=<run:Divide> output=nil error=DivisionByZero()
end Calculator node=<node:Calculator> parentName=Pipeline type=Agent session=<session> run=<run:Calculator> output=nil error=runTerminated(reason: endOnError(nodeName: "Divide", underlying: DivisionByZero()))
begin Cleanup node=<node:Cleanup> parent=<node:Pipeline> parentName=Pipeline type=Function session=<session> run=<run:Cleanup> guards=false/false instructions=nil input={reason: failed}
end Cleanup node=<node:Cleanup> parentName=Pipeline type=Function session=<session> run=<run:Cleanup> output=nil error=runTerminated(reason: endOnError(nodeName: "Divide", underlying: DivisionByZero()))
end Pipeline node=<node:Pipeline> parentName= type=Function session=<session> run=<run:Pipeline> output=nil error=runTerminated(reason: endOnError(nodeName: "Divide", underlying: DivisionByZero()))
"""#
}
