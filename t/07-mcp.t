#!perl
use 5.020;
use strict;
use warnings;
use Test::More;

use Claude::Agent::MCP;

# Test MCP::ToolDefinition
my $tool = Claude::Agent::MCP::ToolDefinition->new(
    name         => 'calculate',
    description  => 'Perform mathematical calculations',
    input_schema => {
        type       => 'object',
        properties => {
            expression => { type => 'string', description => 'Math expression' },
        },
        required => ['expression'],
    },
    handler => sub {
        my ($args) = @_;
        my $expr   = $args->{expression};
        my $result = eval $expr;
        return {
            content => [{ type => 'text', text => "Result: $result" }],
        };
    },
);

isa_ok($tool, 'Claude::Agent::MCP::ToolDefinition');
is($tool->name, 'calculate', 'tool name');
is($tool->description, 'Perform mathematical calculations', 'tool description');
is($tool->input_schema->{type}, 'object', 'input schema type');

# Test to_hash
my $hash = $tool->to_hash;
is($hash->{name}, 'calculate', 'to_hash name');
is($hash->{description}, 'Perform mathematical calculations', 'to_hash description');
is($hash->{inputSchema}{type}, 'object', 'to_hash inputSchema');

# Test execute
my $result = $tool->execute({ expression => '2 + 2' });
is($result->{content}[0]{text}, 'Result: 4', 'tool execution');

# Test execute with error
my $error_tool = Claude::Agent::MCP::ToolDefinition->new(
    name         => 'failing',
    description  => 'Always fails',
    input_schema => {},
    handler      => sub { die "Intentional error" },
);

$result = $error_tool->execute({});
ok($result->{is_error}, 'error tool returns is_error');
like($result->{content}[0]{text}, qr/Intentional error/, 'error message preserved');

# Test MCP::Server (SDK type)
my $server = Claude::Agent::MCP::Server->new(
    name    => 'math-server',
    tools   => [$tool],
    version => '2.0.0',
);

isa_ok($server, 'Claude::Agent::MCP::Server');
is($server->name, 'math-server', 'server name');
is($server->type, 'sdk', 'server type is sdk');
is($server->version, '2.0.0', 'server version');
is(scalar @{$server->tools}, 1, 'server has one tool');

# Test get_tool
my $found = $server->get_tool('calculate');
is($found->name, 'calculate', 'get_tool found tool');

my $not_found = $server->get_tool('nonexistent');
is($not_found, undef, 'get_tool returns undef for missing');

# Test tool_names
my $names = $server->tool_names;
is_deeply($names, ['mcp__math-server__calculate'], 'tool_names returns prefixed names');

# Test server to_hash
$hash = $server->to_hash;
is($hash->{type}, 'sdk', 'server to_hash type');
is($hash->{name}, 'math-server', 'server to_hash name');
is($hash->{version}, '2.0.0', 'server to_hash version');
is(scalar @{$hash->{tools}}, 1, 'server to_hash has tools');
is($hash->{tools}[0]{name}, 'calculate', 'server to_hash tool name');

# Test MCP::StdioServer
my $stdio_server = Claude::Agent::MCP::StdioServer->new(
    command => 'npx',
    args    => ['-y', '@modelcontextprotocol/server-filesystem'],
    env     => { HOME => '/home/user' },
);

isa_ok($stdio_server, 'Claude::Agent::MCP::StdioServer');
is($stdio_server->command, 'npx', 'stdio command');
is($stdio_server->type, 'stdio', 'stdio type');
is_deeply($stdio_server->args, ['-y', '@modelcontextprotocol/server-filesystem'], 'stdio args');
is_deeply($stdio_server->env, { HOME => '/home/user' }, 'stdio env');

$hash = $stdio_server->to_hash;
is($hash->{type}, 'stdio', 'stdio to_hash type');
is($hash->{command}, 'npx', 'stdio to_hash command');
is_deeply($hash->{args}, ['-y', '@modelcontextprotocol/server-filesystem'], 'stdio to_hash args');

# Test MCP::SSEServer
my $sse_server = Claude::Agent::MCP::SSEServer->new(
    url     => 'https://api.example.com/mcp/sse',
    headers => { Authorization => 'Bearer token123' },
);

isa_ok($sse_server, 'Claude::Agent::MCP::SSEServer');
is($sse_server->url, 'https://api.example.com/mcp/sse', 'sse url');
is($sse_server->type, 'sse', 'sse type');
is_deeply($sse_server->headers, { Authorization => 'Bearer token123' }, 'sse headers');

$hash = $sse_server->to_hash;
is($hash->{type}, 'sse', 'sse to_hash type');
is($hash->{url}, 'https://api.example.com/mcp/sse', 'sse to_hash url');

# Test MCP::HTTPServer
my $http_server = Claude::Agent::MCP::HTTPServer->new(
    url     => 'https://api.example.com/mcp',
    headers => { 'X-API-Key' => 'secret' },
);

isa_ok($http_server, 'Claude::Agent::MCP::HTTPServer');
is($http_server->url, 'https://api.example.com/mcp', 'http url');
is($http_server->type, 'http', 'http type');
is_deeply($http_server->headers, { 'X-API-Key' => 'secret' }, 'http headers');

$hash = $http_server->to_hash;
is($hash->{type}, 'http', 'http to_hash type');
is($hash->{url}, 'https://api.example.com/mcp', 'http to_hash url');

# Test integration with Options
use Claude::Agent::Options;

my $options = Claude::Agent::Options->new(
    mcp_servers => {
        math  => $server,
        fs    => $stdio_server,
        api   => $sse_server,
        http  => $http_server,
    },
    allowed_tools => ['mcp__math__calculate', 'Read', 'Glob'],
);

ok($options->has_mcp_servers, 'options has mcp_servers');
is(scalar keys %{$options->mcp_servers}, 4, 'options has 4 mcp servers');
isa_ok($options->mcp_servers->{math}, 'Claude::Agent::MCP::Server');
isa_ok($options->mcp_servers->{fs}, 'Claude::Agent::MCP::StdioServer');
isa_ok($options->mcp_servers->{api}, 'Claude::Agent::MCP::SSEServer');
isa_ok($options->mcp_servers->{http}, 'Claude::Agent::MCP::HTTPServer');

done_testing();
