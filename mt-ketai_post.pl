# $Id$

package MT::Plugin::KetaiPost;

use strict;
use warnings;
use utf8;

use MT::Plugin;
use base qw( MT::Plugin );

use vars qw($PLUGIN_NAME $VERSION);
$PLUGIN_NAME = 'KetaiPost';
$VERSION = '0.1.1';

use KetaiPost::MailBox;
use KetaiPost::Author;

use MT;
my $plugin = MT::Plugin::KetaiPost->new({
    id => 'ketaipost',
    key => __PACKAGE__,
    name => $PLUGIN_NAME,
    version => $VERSION,
    description => <<'DESCRIPTION',
携帯メールを使った記事投稿のためのプラグイン（MT5専用）。
DESCRIPTION
    doc_link => '',
    author_name => 'Yuichi Takeuchi',
    author_link => 'http://takeyu-web.com/',
    schema_version => 0.02,
    object_classes => [ 'KetaiPost::MailBox', 'KetaiPost::Author' ],
    settings => new MT::PluginSettings([
	['default_subject', { Scope => 'blog', Default => '' }],
	['default_subject', { Scope => 'system', Default => '無題' }],
        ['use_debuglog', { Scope => 'system', Default => 0 }],
    ]),
    blog_config_template => \&blog_config_template,
    system_config_template => \&system_config_template,
    registry => {
        object_types => {
            'ketaipost_mailbox' => 'KetaiPost::MailBox',
	    'ketaipost_author' => 'KetaiPost::Author'
        },
        tasks =>  {
            'KetaiPost' => {
                label     => 'KetaiPost',
                # frequency => 1 * 60 * 60,   # no more than every 1 hours
		frequency => 1,
                code      => \&do_ketai_post,
            },
        },
	# 管理画面
	applications => {
	    cms => {
		menus => {
		    'settings:list_ketaipost' => {
			label => 'KetaiPost',
			order => 10100,
			mode => 'list_ketaipost',
			view => 'system',
			system_permission => "administer",
		    }
		},
		methods => {
		    list_ketaipost => '$ketaipost::KetaiPost::CMS::list_ketaipost',
		    select_ketaipost_blog => '$ketaipost::KetaiPost::CMS::select_ketaipost_blog',
		    edit_ketaipost_mailbox => '$ketaipost::KetaiPost::CMS::edit_ketaipost_mailbox',
		    save_ketaipost_mailbox => '$ketaipost::KetaiPost::CMS::save_ketaipost_mailbox',
		    delete_ketaipost_mailbox => '$ketaipost::KetaiPost::CMS::delete_ketaipost_mailbox',
		    edit_ketaipost_author => '$ketaipost::KetaiPost::CMS::edit_ketaipost_author',
		    save_ketaipost_author => '$ketaipost::KetaiPost::CMS::save_ketaipost_author',
		    delete_ketaipost_author => '$ketaipost::KetaiPost::CMS::delete_ketaipost_author',
		}
	    }
	}
    },
});

MT->add_plugin($plugin);

sub instance { $plugin; }

# 「システム」の設定値を取得
# $plugin->get_system_setting($key);
sub get_system_setting {
    my $self = shift;
    my ($value) = @_;
    my %plugin_param;

    # 連想配列 %plugin_param にシステムの設定リストをセット
    $self->load_config(\%plugin_param, 'system');

    $plugin_param{$value}; # 設定の値を返す
}

# 「ブログ/ウェブサイト」の設定値を取得
# ウェブサイトはブログのサブクラス。
# $plugin->get_blog_setting($blog_id, $key);
sub get_blog_setting {
    my $self = shift;
    my ($blog_id, $key) = @_;
    my %plugin_param;

    $self->load_config(\%plugin_param, 'blog:'.$blog_id);

    $plugin_param{$key};
}

# 指定のブログがウェブサイトに属する場合、その設定値を返す
# ウェブサイトが見つからない場合は、undef を返す
# $value = $plugin->get_website_setting($blog_id);
# if(defined($value)) ...
sub get_website_setting {
    my $self = shift;
    my ($blog_id, $key, $ctx) = @_;

    require MT::Blog;
    require MT::Website;
    my $blog = MT::Blog->load($blog_id);
    return undef unless (defined($blog) && $blog->parent_id);
    my $website = MT::Website->load($blog->parent_id);
    return undef unless (defined($website));

    $self->get_blog_setting($website->id, $key);
}

# ブログ -> ウェブサイト -> システム の順に設定を確認
sub get_setting {
    my $self = shift;
    my ($blog_id, $key) = @_;

    my $website_value = $self->get_website_setting($blog_id, $key);
    my $value = $self->get_blog_setting($blog_id, $key);
    if ($value) {
	return $value;
    } elsif (defined($website_value)) {
	return $website_value || $self->get_system_setting($key);;
    }
    $self->get_system_setting($key);
}

use MT::Log;

sub write_log {
    my $self = shift;
    my ($msg, $ref_options) = @_; 
    return unless defined($msg);

    $ref_options ||= {};
    my $ref_default_options = {
	level => MT::Log::INFO,
    };

    $ref_options = {%{$ref_default_options}, %{$ref_options}};
    $ref_options->{message} = '[KetaiPost]'.$msg;

    
    MT->log($ref_options);
}

sub log_info {
    my $self = shift;
    my ($msg, $ref_options) = @_;
    $self->write_log($msg, $ref_options);
}

sub log_debug {
    my $self = shift;
    my ($msg, $ref_options) = @_;
    return unless defined($msg);
    return unless instance->get_system_setting('use_debuglog');
    
    $ref_options ||= {};
    my $ref_default_options = {
	level => MT::Log::DEBUG,
    };
    $ref_options = {%{$ref_default_options}, %{$ref_options}};

    $self->write_log('[debug]'.$msg, $ref_options);
}

sub log_error {
    my $self = shift;
    my ($msg, $ref_options) = @_;
    return unless defined($msg);
    
    $ref_options ||= {};
    my $ref_default_options = {
	level => MT::Log::ERROR,
    };
    $ref_options = {%{$ref_default_options}, %{$ref_options}};

    $self->write_log('[error]'.$msg, $ref_options);
}

sub blog_config_template {
    my $tmpl = <<'EOT';
<mtapp:setting id="default_subject" label="デフォルトの記事タイトル:">
  <input type="text" name="default_subject" value="<mt:var name="default_subject" encode_html="1" />" class="full-width" /><br />
  ブログ -> ウェブサイト -> システム の順で優先されます。
</mtapp:setting>
EOT
}

sub system_config_template {
    my $tmpl = <<'EOT';
<mtapp:setting id="default_subject" label="デフォルトの記事タイトル:">
  <input type="text" name="default_subject" value="<mt:var name="default_subject" encode_html="1" />" class="full-width" /><br />
  ブログ -> ウェブサイト -> システム の順で優先されます。
</mtapp:setting>
<mtapp:setting id="use_debuglog" label="デバッグログ出力:">
  <mt:if name="use_debuglog">
    <input type="radio" id="use_debuglog_1" name="use_debuglog" value="1" checked="checked" /><label for="use_debuglog_1">する</label>&nbsp;
    <input type="radio" id="use_debuglog_0" name="use_debuglog" value="0" /><label for="use_debuglog_0">しない</label>
  <mt:else>
    <input type="radio" id="use_debuglog_1" name="use_debuglog" value="1" /><label for="use_debuglog_1">する</label>&nbsp;
    <input type="radio" id="use_debuglog_0" name="use_debuglog" value="0" checked="checked" /><label for="use_debuglog_0">しない</label>
  </mt:if>
</mtapp:setting>
EOT
}

#----- Task

sub do_ketai_post {
    require KetaiPost::Task;
    my $task = KetaiPost::Task->new(instance);
    $task->run;
}

1;
